import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var isLoggedIn = false
    @Published private(set) var purifiers: [Purifier] = [] {
        didSet { updateMenuIcon() }
    }
    @Published var selectedID: String?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var lastUpdated: Date?

    @AppStorage("email") var email = ""
    @AppStorage("countryCode") var countryCode = Locale.current.region?.identifier ?? "US"

    private let client: VeSyncClient
    private var pollTask: Task<Void, Never>?

    /// Drives the spinning fan in the menu bar. Kept outside @Published so the
    /// animation doesn't redraw the whole panel.
    let menuIcon = MenuIconAnimator()
    let updater = Updater()

    var anyOn: Bool { purifiers.contains { $0.status?.isOn == true } }

    var selected: Purifier? {
        purifiers.first { $0.id == selectedID } ?? purifiers.first
    }

    private func updateMenuIcon() {
        let running = purifiers.compactMap(\.status).filter(\.isOn)
        let speed = running.map { max($0.fanLevel, 1) }.max() ?? 0
        // Show the worst air quality reported by any purifier that has a sensor.
        let air = purifiers.filter(\.caps.hasAirQuality).compactMap(\.status?.airQualityLevel).max()
        menuIcon.update(running: !running.isEmpty, speed: speed, airQuality: air)
    }

    init() {
        let saved = Keychain.credentials
        client = VeSyncClient(credentials: saved)
        if saved != nil {
            isLoggedIn = true
            startPolling()
        }
        updater.start()
    }

    /// For snapshots: no Keychain access, no network.
    init(noAutoLogin: Void) {
        client = VeSyncClient(credentials: nil)
    }

    func loadDemo(_ items: [Purifier]) {
        purifiers = items
        isLoggedIn = true
        lastUpdated = Date()
    }

    // MARK: - Account

    func login(email: String, password: String) async {
        isLoading = true
        errorMessage = nil
        do {
            let creds = try await client.login(email: email, password: password, countryCode: countryCode)
            self.email = email
            Keychain.password = password
            Keychain.credentials = creds
            isLoading = false
            isLoggedIn = true
            startPolling()
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    func logout() {
        pollTask?.cancel()
        pollTask = nil
        Keychain.password = nil
        Keychain.credentials = nil
        Task { await client.setCredentials(nil) }
        purifiers = []
        isLoggedIn = false
        lastUpdated = nil
    }

    /// Runs `work`, and if VeSync says the token expired, logs in again with the
    /// saved password and retries once.
    private func withReauth<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as VeSyncError where error.isAuthError || error.isNotLoggedIn {
            guard let password = Keychain.password, !email.isEmpty else {
                logout()
                throw error
            }
            let creds = try await client.login(email: email, password: password, countryCode: countryCode)
            Keychain.credentials = creds
            return try await work()
        }
    }

    // MARK: - Status

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }

    func refresh() async {
        guard isLoggedIn, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let devices = try await withReauth { try await client.devices() }
            var updated: [Purifier] = []
            for device in devices {
                guard let caps = PurifierCapabilities.forDeviceType(device.deviceType) else { continue }
                var purifier = Purifier(device: device, caps: caps)
                if caps.proto == .unsupported {
                    purifier.error = "This model uses an older API that LevoitBar doesn't support yet."
                } else if device.isOnline {
                    do {
                        let raw = try await client.bypass(device, method: "getPurifierStatus")
                        purifier.status = PurifierStatus.parse(raw, proto: caps.proto)
                    } catch {
                        purifier.error = error.localizedDescription
                    }
                }
                updated.append(purifier)
            }
            purifiers = updated
            errorMessage = nil
            lastUpdated = Date()
        } catch {
            if isLoggedIn { errorMessage = error.localizedDescription }
        }
    }

    // MARK: - Commands

    func send(_ command: PurifierCommand, to purifier: Purifier) async {
        guard let index = purifiers.firstIndex(where: { $0.id == purifier.id }) else { return }
        let proto = purifier.caps.proto

        // Manual mode is entered by setting a fan speed.
        var command = command
        if case .mode(.manual) = command {
            let level = max(purifier.status?.manualLevel ?? 1, purifier.caps.fanLevels.lowerBound)
            command = .fanLevel(min(level, purifier.caps.fanLevels.upperBound))
        }

        applyOptimistically(command, at: index)
        let (method, data) = command.request(for: proto)
        do {
            _ = try await withReauth { try await client.bypass(purifier.device, method: method, data: data) }
            // Read back what the purifier actually did.
            let raw = try await client.bypass(purifier.device, method: "getPurifierStatus")
            if let i = purifiers.firstIndex(where: { $0.id == purifier.id }) {
                purifiers[i].status = PurifierStatus.parse(raw, proto: proto)
                purifiers[i].error = nil
            }
        } catch {
            errorMessage = error.localizedDescription
            await refresh()
        }
    }

    private func applyOptimistically(_ command: PurifierCommand, at index: Int) {
        guard var status = purifiers[index].status else { return }
        switch command {
        case .power(let on): status.isOn = on
        case .fanLevel(let level):
            status.isOn = true
            status.mode = PurifierMode.manual.rawValue
            status.fanLevel = level
            status.manualLevel = level
        case .mode(let mode):
            status.isOn = true
            status.mode = mode.rawValue
        case .display(let on): status.displayOn = on
        case .childLock(let on): status.childLock = on
        }
        purifiers[index].status = status
    }
}

private extension VeSyncError {
    var isNotLoggedIn: Bool {
        if case .notLoggedIn = self { return true }
        return false
    }
}
