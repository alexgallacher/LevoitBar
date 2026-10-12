import AppKit
import Foundation

/// Keeps LevoitBar up to date from the GitHub Releases of the project repo.
///
/// Each release built by `.github/workflows/release.yml` carries a
/// `LevoitBar.zip` asset. When a release's version is newer than the running app,
/// the updater downloads it, swaps the app bundle in place and relaunches.
@MainActor
final class Updater: ObservableObject {
    static let repo = "alexgallacher/LevoitBar"

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case installing(version: String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// Install updates automatically as soon as they're found.
    var autoInstall: Bool {
        get { UserDefaults.standard.object(forKey: "autoInstallUpdates") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoInstallUpdates"); objectWillChange.send() }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private var pending: (version: String, url: URL)?
    private var loop: Task<Void, Never>?

    /// Updating only makes sense for a real .app bundle (not `swift run`).
    private var canSelfUpdate: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func start() {
        guard loop == nil, canSelfUpdate else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            while !Task.isCancelled {
                await self?.check(userInitiated: false)
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
            }
        }
    }

    func check(userInitiated: Bool = true) async {
        if case .installing = state { return }
        state = .checking
        do {
            guard let release = try await latestRelease() else {
                state = userInitiated ? .upToDate : .idle
                return
            }
            if Self.isNewer(release.version, than: currentVersion) {
                pending = release
                state = .available(version: release.version)
                if autoInstall && !userInitiated { await install() }
            } else {
                state = userInitiated ? .upToDate : .idle
            }
        } catch {
            state = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    func install() async {
        guard let pending, canSelfUpdate else { return }
        state = .installing(version: pending.version)
        do {
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("LevoitBarUpdate-\(UUID().uuidString)")
            try fm.createDirectory(at: work, withIntermediateDirectories: true)

            let (download, response) = try await URLSession.shared.download(for: request(pending.url, accept: "application/octet-stream"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Download failed") }
            let zip = work.appendingPathComponent("LevoitBar.zip")
            try fm.moveItem(at: download, to: zip)

            try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
            let newApp = work.appendingPathComponent("LevoitBar.app")
            guard let bundle = Bundle(url: newApp),
                  bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw UpdateError("The download isn't a LevoitBar app")
            }

            // Swap the bundle once this process has quit, then relaunch.
            let target = Bundle.main.bundleURL.path
            let script = """
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
            rm -rf "\(target)" && mv "\(newApp.path)" "\(target)" && xattr -dr com.apple.quarantine "\(target)" 2>/dev/null
            open "\(target)"
            rm -rf "\(work.path)"
            """
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - GitHub

    private struct UpdateError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private func latestRelease() async throws -> (version: String, url: URL)? {
        let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
        let (data, response) = try await URLSession.shared.data(for: request(url, accept: "application/vnd.github+json"))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }   // no releases yet
        guard status == 200 else { throw UpdateError("GitHub returned HTTP \(status)") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let zip = assets.first(where: { ($0["name"] as? String) == "LevoitBar.zip" }) else {
            return nil
        }
        // Private repos must download through the API asset URL; public ones can use either.
        let assetURL = (zip["url"] as? String).flatMap(URL.init(string:))
        guard let assetURL else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return (version, assetURL)
    }

    private func request(_ url: URL, accept: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(accept, forHTTPHeaderField: "Accept")
        r.setValue("LevoitBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        if let token = Keychain.githubToken {
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return r
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("\(tool) failed") }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
