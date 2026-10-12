import Foundation

/// Which command dialect a purifier speaks over the bypassV2 endpoint.
enum PurifierProtocol {
    /// Core 200S/300S/400S/600S and LV-RH131S: `enabled`, `level`, `mode`, ...
    case core
    /// Vital 100S/200S, Everest Air, Sprout: `powerSwitch`, `manualSpeedLevel`, `workMode`, ...
    case v2
    /// Older models on the legacy API (e.g. LV-PUR131S). Listed but not controllable.
    case unsupported
}

enum PurifierMode: String, CaseIterable, Identifiable {
    case manual, auto, sleep, pet, turbo
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .manual: return "hand.raised"
        case .auto: return "a.circle"
        case .sleep: return "moon.zzz"
        case .pet: return "pawprint"
        case .turbo: return "hare"
        }
    }
}

/// What a given model can do, based on pyvesync's device map.
struct PurifierCapabilities {
    let modelName: String
    let proto: PurifierProtocol
    let fanLevels: ClosedRange<Int>
    let modes: [PurifierMode]
    let hasAirQuality: Bool

    static func forDeviceType(_ type: String) -> PurifierCapabilities? {
        let t = type.uppercased()
        func has(_ prefixes: String...) -> Bool { prefixes.contains { t.hasPrefix($0) } }

        if has("CORE200S", "LAP-C201S", "LAP-C202S") {
            return .init(modelName: "Core 200S", proto: .core, fanLevels: 1...3,
                         modes: [.manual, .sleep], hasAirQuality: false)
        }
        if has("CORE300S", "LAP-C301S", "LAP-C302S") {
            return .init(modelName: "Core 300S", proto: .core, fanLevels: 1...3,
                         modes: [.manual, .auto, .sleep], hasAirQuality: true)
        }
        if has("CORE400S", "LAP-C401S") {
            return .init(modelName: "Core 400S", proto: .core, fanLevels: 1...4,
                         modes: [.manual, .auto, .sleep], hasAirQuality: true)
        }
        if has("CORE600S", "LAP-C601S") {
            return .init(modelName: "Core 600S", proto: .core, fanLevels: 1...4,
                         modes: [.manual, .auto, .sleep], hasAirQuality: true)
        }
        if has("LV-RH131S") {
            return .init(modelName: "LV-H131S", proto: .core, fanLevels: 1...3,
                         modes: [.manual, .auto, .sleep], hasAirQuality: true)
        }
        if has("LAP-V102S") {
            return .init(modelName: "Vital 100S", proto: .v2, fanLevels: 1...4,
                         modes: [.manual, .auto, .sleep, .pet], hasAirQuality: true)
        }
        if has("LAP-V201") {
            return .init(modelName: "Vital 200S", proto: .v2, fanLevels: 1...4,
                         modes: [.manual, .auto, .sleep, .pet], hasAirQuality: true)
        }
        if has("LAP-EL551S") {
            return .init(modelName: "Everest Air", proto: .v2, fanLevels: 1...3,
                         modes: [.manual, .auto, .sleep, .turbo], hasAirQuality: true)
        }
        if has("LAP-B851S", "LAP-BAY") {
            return .init(modelName: "Sprout Air", proto: .v2, fanLevels: 1...3,
                         modes: [.manual, .auto, .sleep], hasAirQuality: true)
        }
        if has("LV-PUR131S") {
            return .init(modelName: "LV-PUR131S", proto: .unsupported, fanLevels: 1...3,
                         modes: [], hasAirQuality: true)
        }
        if has("LAP-C") {
            // Unknown Core variant: assume the common Core feature set.
            return .init(modelName: type, proto: .core, fanLevels: 1...3,
                         modes: [.manual, .auto, .sleep], hasAirQuality: true)
        }
        if has("LAP-") {
            // Unknown newer purifier: assume the Vital-style protocol.
            return .init(modelName: type, proto: .v2, fanLevels: 1...4,
                         modes: [.manual, .auto, .sleep], hasAirQuality: true)
        }
        return nil
    }
}

/// Live state read from the purifier.
struct PurifierStatus: Equatable {
    var isOn: Bool
    var mode: String
    var fanLevel: Int        // current speed (0 when idle)
    var manualLevel: Int     // speed used in manual mode
    var filterLife: Int?
    var airQualityLevel: Int?   // 1 = excellent ... 4 = poor
    var pm25: Int?
    var displayOn: Bool
    var childLock: Bool

    /// Levoit's own air-quality scale, matching the purifier's light ring and the
    /// VeSync app: blue = excellent, green = good, orange = moderate, red = poor.
    static func airQualityRGB(_ level: Int?) -> (r: Double, g: Double, b: Double)? {
        switch level {
        case 1: return (0.20, 0.55, 1.00)
        case 2: return (0.20, 0.80, 0.35)
        case 3: return (1.00, 0.60, 0.10)
        case 4: return (1.00, 0.25, 0.25)
        default: return nil
        }
    }

    var airQualityLabel: String? {
        switch airQualityLevel {
        case 1: return "Excellent"
        case 2: return "Good"
        case 3: return "Moderate"
        case 4: return "Poor"
        default: return nil
        }
    }

    static func parse(_ r: [String: Any], proto: PurifierProtocol) -> PurifierStatus {
        typealias C = VeSyncClient
        switch proto {
        case .v2:
            var fan = C.int(r["fanSpeedLevel"]) ?? 0
            if fan == 255 { fan = 0 }
            return PurifierStatus(
                isOn: (C.int(r["powerSwitch"]) ?? 0) == 1,
                mode: (r["workMode"] as? String) ?? "manual",
                fanLevel: fan,
                manualLevel: C.int(r["manualSpeedLevel"]) ?? fan,
                filterLife: C.int(r["filterLifePercent"]),
                airQualityLevel: C.int(r["AQLevel"]),
                pm25: C.int(r["PM25"]),
                displayOn: (C.int(r["screenSwitch"]) ?? 1) == 1,
                childLock: (C.int(r["childLockSwitch"]) ?? 0) == 1
            )
        default:
            let level = C.int(r["level"]) ?? 0
            let config = r["configuration"] as? [String: Any]
            return PurifierStatus(
                isOn: C.bool(r["enabled"]) ?? false,
                mode: (r["mode"] as? String) ?? "manual",
                fanLevel: level,
                manualLevel: C.int(r["levelNew"]).flatMap { $0 > 0 ? $0 : nil } ?? level,
                filterLife: C.int(r["filter_life"]),
                airQualityLevel: C.int(r["air_quality"]),
                pm25: C.int(r["air_quality_value"]),
                displayOn: C.bool(config?["display"]) ?? C.bool(r["display"]) ?? true,
                childLock: C.bool(r["child_lock"]) ?? false
            )
        }
    }
}

/// A purifier as shown in the menu: cloud listing + capabilities + latest status.
struct Purifier: Identifiable, Equatable {
    static func == (lhs: Purifier, rhs: Purifier) -> Bool {
        lhs.device == rhs.device && lhs.status == rhs.status && lhs.error == rhs.error
    }

    var id: String { device.cid }
    var device: VeSyncDevice
    var caps: PurifierCapabilities
    var status: PurifierStatus?
    var error: String?

    var isControllable: Bool { caps.proto != .unsupported && device.isOnline }
}

/// Builds the bypassV2 payloads for each command, per protocol.
enum PurifierCommand {
    case power(Bool)
    case fanLevel(Int)
    case mode(PurifierMode)
    case display(Bool)
    case childLock(Bool)

    func request(for proto: PurifierProtocol) -> (method: String, data: [String: Any]) {
        switch (self, proto) {
        case (.power(let on), .v2):
            return ("setSwitch", ["powerSwitch": on ? 1 : 0, "switchIdx": 0])
        case (.power(let on), _):
            return ("setSwitch", ["enabled": on, "id": 0])

        case (.fanLevel(let level), .v2):
            return ("setLevel", ["levelIdx": 0, "manualSpeedLevel": level, "levelType": "wind"])
        case (.fanLevel(let level), _):
            return ("setLevel", ["id": 0, "level": level, "type": "wind"])

        case (.mode(let mode), .v2):
            return ("setPurifierMode", ["workMode": mode.rawValue])
        case (.mode(let mode), _):
            return ("setPurifierMode", ["mode": mode.rawValue])

        case (.display(let on), .v2):
            return ("setDisplay", ["screenSwitch": on ? 1 : 0])
        case (.display(let on), _):
            return ("setDisplay", ["state": on])

        case (.childLock(let on), .v2):
            return ("setChildLock", ["childLockSwitch": on ? 1 : 0])
        case (.childLock(let on), _):
            return ("setChildLock", ["child_lock": on])
        }
    }
}
