import AppKit
import SwiftUI

/// Tracks when animation and polling are worth doing: whether the panel is on
/// screen, whether the displays are awake and the user session is active, and
/// whether the user asked macOS to reduce motion.
@MainActor
final class ActivityMonitor: ObservableObject {
    @Published private(set) var panelVisible = false
    @Published private(set) var screensAwake = true
    @Published private(set) var sessionActive = true
    @Published private(set) var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    /// Called after any of the above changes.
    var onChange: (() -> Void)?

    /// Someone could be looking at the Mac right now.
    var userPresent: Bool { screensAwake && sessionActive }
    var animateMenuIcon: Bool { userPresent && !reduceMotion }
    var animatePanel: Bool { panelVisible && userPresent && !reduceMotion }

    private var tokens: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        func observe(_ name: Notification.Name, _ apply: @escaping (ActivityMonitor) -> Void) {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    apply(self)
                    self.onChange?()
                }
            })
        }
        observe(NSWorkspace.screensDidSleepNotification) { $0.screensAwake = false }
        observe(NSWorkspace.screensDidWakeNotification) { $0.screensAwake = true }
        observe(NSWorkspace.sessionDidResignActiveNotification) { $0.sessionActive = false }
        observe(NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionActive = true }
        observe(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) {
            $0.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    func setPanelVisible(_ visible: Bool) {
        guard visible != panelVisible else { return }
        panelVisible = visible
        onChange?()
    }
}
