import CryptoKit
import Foundation

/// Session details returned by a successful VeSync login.
struct VeSyncCredentials: Codable, Equatable {
    var token: String
    var accountID: String
    var countryCode: String
    var region: String
}

/// One device as listed by the VeSync cloud.
struct VeSyncDevice: Identifiable, Equatable {
    var id: String { cid }
    let cid: String
    let name: String
    let deviceType: String
    let configModule: String
    let connectionStatus: String
    let deviceStatus: String

    var isOnline: Bool { connectionStatus.lowercased() == "online" }
}

enum VeSyncError: LocalizedError {
    case notLoggedIn
    case http(Int)
    case api(code: Int, message: String?)
    case badResponse(String)
    case deviceOffline

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "Not signed in to VeSync."
        case .http(let status): return "VeSync server returned HTTP \(status)."
        case .api(let code, let message):
            if let message, !message.isEmpty { return "\(message) (code \(code))" }
            return "VeSync error code \(code)."
        case .badResponse(let what): return "Unexpected response from VeSync (\(what))."
        case .deviceOffline: return "The purifier is offline."
        }
    }

    /// Errors that mean the token is no longer valid and a fresh login may fix things.
    var isAuthError: Bool {
        if case .api(let code, _) = self {
            return [-11001000, -11012022, 4001004, -11003000].contains(code)
        }
        return false
    }
}

/// Minimal client for Levoit's VeSync cloud API.
///
/// Request shapes mirror the open-source pyvesync library (v3.x), which tracks
/// what the official VeSync phone app sends.
actor VeSyncClient {
    private enum Const {
        static let appVersion = "5.6.60"
        static let appID = "eldodkfj"
        static let phoneBrand = "LevoitBar"
        static let phoneOS = "Android"
        static let clientType = "vesyncApp"
        static let userAgent = "okhttp/3.12.1"
        static let crossRegionCode = -11260022
    }

    private(set) var credentials: VeSyncCredentials?
    private let session: URLSession
    private var callNumber = 0
    private let terminalID: String
    private var timeZone: String { TimeZone.current.identifier }

    init(credentials: VeSyncCredentials? = nil) {
        self.credentials = credentials
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)

        let key = "VeSyncTerminalID"
        if let saved = UserDefaults.standard.string(forKey: key) {
            terminalID = saved
        } else {
            let id = "2" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            UserDefaults.standard.set(id, forKey: key)
            terminalID = id
        }
    }

    func setCredentials(_ creds: VeSyncCredentials?) {
        credentials = creds
    }

    // MARK: - Login

    /// Two-step login used by current VeSync apps: exchange email/password for an
    /// authorize code, then exchange that code for a token. If the account lives in
    /// another region (e.g. EU), the server says so and we retry there.
    ///
    /// `passwordHash` is the MD5 of the password, which is what VeSync's API expects.
    /// The app only ever keeps this hash, never the plain password.
    func login(email: String, passwordHash: String, countryCode: String) async throws -> VeSyncCredentials {
        let authBody: [String: Any] = [
            "email": email,
            "method": "authByPWDOrOTM",
            "password": passwordHash,
            "acceptLanguage": "en",
            "accountID": "",
            "authProtocolType": "generic",
            "clientInfo": Const.phoneBrand,
            "clientType": Const.clientType,
            "clientVersion": "VeSync \(Const.appVersion)",
            "debugMode": false,
            "osInfo": Const.phoneOS,
            "terminalId": terminalID,
            "timeZone": timeZone,
            "token": "",
            "userCountryCode": countryCode,
            "appID": Const.appID,
            "sourceAppID": Const.appID,
            "traceId": nextTraceID(),
        ]
        let authResp = try await post("/globalPlatform/api/accountAuth/v1/authByPWDOrOTM",
                                      region: Self.region(forCountry: countryCode), body: authBody)
        try Self.checkCode(authResp)
        guard let authResult = authResp["result"] as? [String: Any],
              let authorizeCode = authResult["authorizeCode"] as? String else {
            throw VeSyncError.badResponse("missing authorizeCode")
        }

        var country = countryCode
        var region = Self.region(forCountry: countryCode)
        var bizToken: String?

        for _ in 0..<2 {
            var loginBody: [String: Any] = [
                "method": "loginByAuthorizeCode4Vesync",
                "authorizeCode": authorizeCode,
                "acceptLanguage": "en",
                "accountID": "",
                "clientInfo": Const.phoneBrand,
                "clientType": Const.clientType,
                "clientVersion": "VeSync \(Const.appVersion)",
                "debugMode": false,
                "emailSubscriptions": false,
                "osInfo": Const.phoneOS,
                "terminalId": terminalID,
                "timeZone": timeZone,
                "token": "",
                "userCountryCode": country,
                "traceId": nextTraceID(),
            ]
            if let bizToken {
                loginBody["bizToken"] = bizToken
                loginBody["regionChange"] = "lastRegion"
            }

            let resp = try await post("/user/api/accountManage/v1/loginByAuthorizeCode4Vesync",
                                      region: region, body: loginBody)
            let code = Self.int(resp["code"]) ?? -1
            let result = resp["result"] as? [String: Any] ?? [:]

            if code == Const.crossRegionCode {
                country = (result["countryCode"] as? String) ?? country
                region = (result["currentRegion"] as? String) ?? Self.region(forCountry: country)
                bizToken = result["bizToken"] as? String
                continue
            }
            try Self.checkCode(resp)
            guard let token = result["token"] as? String,
                  let accountID = Self.string(result["accountID"]) else {
                throw VeSyncError.badResponse("missing token")
            }
            let creds = VeSyncCredentials(
                token: token,
                accountID: accountID,
                countryCode: (result["countryCode"] as? String) ?? country,
                region: (result["currentRegion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? region
            )
            credentials = creds
            return creds
        }
        throw VeSyncError.badResponse("region redirect loop")
    }

    // MARK: - Devices

    func devices() async throws -> [VeSyncDevice] {
        guard let creds = credentials else { throw VeSyncError.notLoggedIn }
        let body: [String: Any] = [
            "token": creds.token,
            "accountID": creds.accountID,
            "timeZone": timeZone,
            "method": "devices",
            "pageNo": 1,
            "pageSize": 100,
            "appVersion": Const.appVersion,
            "phoneBrand": Const.phoneBrand,
            "phoneOS": Const.phoneOS,
            "acceptLanguage": "en",
            "traceId": String(Int(Date().timeIntervalSince1970)),
        ]
        let resp = try await post("/cloud/v1/deviceManaged/devices", region: creds.region, body: body)
        try Self.checkCode(resp)
        guard let result = resp["result"] as? [String: Any] else {
            throw VeSyncError.badResponse("missing device list")
        }
        let list = result["list"] as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let cid = item["cid"] as? String,
                  let type = item["deviceType"] as? String else { return nil }
            var connection = (item["connectionStatus"] as? String) ?? "offline"
            var status = (item["deviceStatus"] as? String) ?? "off"
            if let prop = item["deviceProp"] as? [String: Any] {
                if let c = prop["connectionStatus"] as? String { connection = c }
                if let p = Self.int(prop["powerSwitch"]) { status = p == 1 ? "on" : "off" }
            }
            return VeSyncDevice(
                cid: cid,
                name: (item["deviceName"] as? String) ?? type,
                deviceType: type,
                configModule: (item["configModule"] as? String) ?? "",
                connectionStatus: connection,
                deviceStatus: status
            )
        }
    }

    // MARK: - Device commands

    /// Send a "bypassV2" command to a device and return the device's inner result.
    func bypass(_ device: VeSyncDevice, method: String, data: [String: Any] = [:]) async throws -> [String: Any] {
        guard let creds = credentials else { throw VeSyncError.notLoggedIn }
        let body: [String: Any] = [
            "acceptLanguage": "en",
            "appVersion": Const.appVersion,
            "phoneBrand": Const.phoneBrand,
            "phoneOS": Const.phoneOS,
            "accountID": creds.accountID,
            "cid": device.cid,
            "configModule": device.configModule,
            "configModel": device.configModule,
            "deviceId": device.cid,
            "debugMode": false,
            "traceId": String(Int(Date().timeIntervalSince1970)),
            "timeZone": timeZone,
            "token": creds.token,
            "userCountryCode": creds.countryCode,
            "method": "bypassV2",
            "payload": ["method": method, "source": "APP", "data": data] as [String: Any],
        ]
        let resp = try await post("/cloud/v2/deviceManaged/bypassV2", region: creds.region, body: body)
        let code = Self.int(resp["code"]) ?? -1
        if code == 11 || code == -11300030 { throw VeSyncError.deviceOffline }
        try Self.checkCode(resp)
        guard let outer = resp["result"] as? [String: Any] else {
            throw VeSyncError.badResponse("missing result")
        }
        let innerCode = Self.int(outer["code"]) ?? 0
        if innerCode != 0 {
            throw VeSyncError.api(code: innerCode, message: outer["msg"] as? String)
        }
        return outer["result"] as? [String: Any] ?? [:]
    }

    // MARK: - Plumbing

    private func post(_ path: String, region: String, body: [String: Any]) async throws -> [String: Any] {
        let url = Self.baseURL(forRegion: region).appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(Const.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw VeSyncError.http(http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VeSyncError.badResponse("not JSON")
        }
        return json
    }

    private func nextTraceID() -> String {
        callNumber += 1
        let start = terminalID.index(terminalID.endIndex, offsetBy: -5)
        let end = terminalID.index(before: terminalID.endIndex)
        return "APP\(terminalID[start..<end])\(Int(Date().timeIntervalSince1970))-\(String(format: "%05d", callNumber))"
    }

    private static func checkCode(_ resp: [String: Any]) throws {
        let code = int(resp["code"]) ?? -1
        if code != 0 {
            throw VeSyncError.api(code: code, message: resp["msg"] as? String)
        }
    }

    static func region(forCountry country: String) -> String {
        ["US", "CA", "MX", "JP"].contains(country.uppercased()) ? "US" : "EU"
    }

    static func baseURL(forRegion region: String) -> URL {
        region.uppercased() == "EU"
            ? URL(string: "https://smartapi.vesync.eu")!
            : URL(string: "https://smartapi.vesync.com")!
    }

    static func md5(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let n as NSNumber: return n.intValue != 0
        case let s as String: return ["1", "true", "on"].contains(s.lowercased())
        default: return nil
        }
    }
}
