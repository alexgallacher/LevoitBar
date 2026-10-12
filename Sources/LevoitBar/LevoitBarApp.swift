import AppKit
import SwiftUI

@main
struct LevoitBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Menu-bar only: no Dock icon, even when launched with `swift run`.
        NSApplication.shared.setActivationPolicy(.accessory)
        MainActor.assumeIsolated { Snapshot.runIfRequested() }
    }

    var body: some Scene {
        // The menu-bar item and panel are plain AppKit (see StatusBarController).
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--demo` runs with a sample purifier and no account (for design and profiling).
        let model = CommandLine.arguments.contains("--demo") ? AppModel(demo: true) : AppModel()
        controller = StatusBarController(model: model)
    }
}

/// Owns the menu-bar item and the panel that drops down from it.
///
/// This used to be a SwiftUI `MenuBarExtra`, but SwiftUI watches the status
/// button and pushes its own copy of the label back on every change, so each
/// frame of the spinning fan was drawn several times over. Driving the
/// `NSStatusItem` directly means one image swap per frame and nothing else.
@MainActor
final class StatusBarController: NSObject {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: MenuPanel
    private var clickMonitor: Any?
    private var resizeToken: NSObjectProtocol?
    private var resignToken: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        let root = ContentView()
            .environmentObject(model)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        let host = NSHostingView(rootView: root)
        panel = MenuPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize))
        panel.contentView = host
        super.init()

        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            model.menuIcon.attach(to: item)
        }

        // Keep the panel's top edge pinned under the menu bar as its content grows or shrinks.
        resizeToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.position() } }
        resignToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.close() } }
        panel.onCancel = { [weak self] in self?.close() }
    }

    private var lastClosed = Date.distantPast

    @objc private func toggle() {
        if panel.isVisible {
            close()
        } else if Date().timeIntervalSince(lastClosed) > 0.25 {
            // Clicking the icon while the panel is open closes it on resign-key
            // just before this runs; don't immediately reopen it.
            show()
        }
    }

    private func show() {
        position()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        item.button?.highlight(true)
        model.activity.setPanelVisible(true)
        Task { await model.refreshIfStale() }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        lastClosed = Date()
        item.button?.highlight(false)
        model.activity.setPanelVisible(false)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    private func position() {
        guard let button = item.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frame.size
        var x = anchor.midX - size.width / 2
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        let origin = NSPoint(x: x.rounded(), y: (anchor.minY - 6 - size.height).rounded())
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }
}

/// Borderless floating panel that can take keyboard focus (for the login form)
/// without pulling the app into the foreground like a normal window.
final class MenuPanel: NSPanel {
    var onCancel: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Spins the menu-bar fan while a purifier is running, faster at higher speeds.
///
/// Kept cheap on purpose: frames are rendered once and reused (the fan has four
/// blades, so 90° of rotation covers every frame), the timer runs at a modest
/// rate with tolerance so macOS can coalesce wake-ups, and the animation stops
/// entirely when the displays sleep, the user switches away, or Reduce Motion is on.
@MainActor
final class MenuIconAnimator {
    /// The icon currently shown (also used by `--icons`).
    private(set) var image: NSImage
    private weak var item: NSStatusItem?

    private static let fps: Double = 20
    private static let degreesPerFrame: Double = 3
    private static let frameCount = Int(90 / degreesPerFrame)
    private static let symbol: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let base = NSImage(systemSymbolName: "fan", accessibilityDescription: "LevoitBar")
            ?? NSImage(systemSymbolName: "wind", accessibilityDescription: "LevoitBar")!
        return base.withSymbolConfiguration(config) ?? base
    }()

    private var frame = 0
    private var framesPerTick = 1
    private var running = false
    private var allowed = true
    private var timer: Timer?
    /// Air-quality colour; nil means a plain monochrome menu-bar icon.
    private var tint: NSColor?
    /// Rendered frames for the current tint and appearance. Key -1 is the idle icon.
    private var cache: [Int: NSImage] = [:]
    private var appearanceObservation: NSKeyValueObservation?

    init() {
        image = Self.render(angle: 0, dimmed: true, tint: nil)
        // labelColor resolves differently in light and dark menu bars.
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in
                self?.cache.removeAll()
                self?.showCurrent()
            }
        }
    }

    func attach(to item: NSStatusItem) {
        self.item = item
        item.button?.image = image
    }

    func update(running: Bool, speed: Int, airQuality: Int?) {
        let newTint = PurifierStatus.airQualityRGB(airQuality).map {
            NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: 1)
        }
        if newTint != tint {
            tint = newTint
            cache.removeAll()
        }
        self.running = running
        // Same spin speeds as before: 220°/s at speed 1 up to 520°/s at speed 4.
        let degreesPerSecond = (6 + 5 * Double(max(speed, 1))) * Self.fps
        framesPerTick = max(1, Int((degreesPerSecond / Self.fps / Self.degreesPerFrame).rounded()))
        syncTimer()
        showCurrent()
    }

    /// Whether animation is currently worthwhile (screens awake, no Reduce Motion).
    func setAllowed(_ allowed: Bool) {
        guard allowed != self.allowed else { return }
        self.allowed = allowed
        syncTimer()
        showCurrent()
    }

    private func syncTimer() {
        let shouldRun = running && allowed
        if shouldRun, timer == nil {
            let t = Timer(timeInterval: 1 / Self.fps, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            t.tolerance = 0.3 / Self.fps
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !shouldRun, let t = timer {
            t.invalidate()
            timer = nil
        }
    }

    private func tick() {
        frame = (frame + framesPerTick) % Self.frameCount
        showCurrent()
    }

    private func showCurrent() {
        let key = running ? frame : -1
        let next: NSImage
        if let cached = cache[key] {
            next = cached
        } else {
            next = Self.render(angle: -Double(frame) * Self.degreesPerFrame, dimmed: !running, tint: tint)
            cache[key] = next
        }
        // Only touch the status item when the picture actually changes: every
        // swap makes macOS redraw the menu bar's copy of the item.
        guard next !== image else { return }
        image = next
        item?.button?.image = next
    }

    private static func render(angle: Double, dimmed: Bool, tint: NSColor?) -> NSImage {
        let fanBox: CGFloat = 18
        let dot: CGFloat = 7
        let gap: CGFloat = 3
        let size = NSSize(width: tint == nil ? fanBox : fanBox + gap + dot + 2, height: fanBox)

        let img = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            // Fan, drawn in the menu bar's own text colour (black or white).
            ctx.saveGState()
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.translateBy(x: fanBox / 2, y: rect.midY)
            ctx.rotate(by: CGFloat(angle * .pi / 180))
            let s = symbol.size
            symbol.draw(in: NSRect(x: -s.width / 2, y: -s.height / 2, width: s.width, height: s.height),
                        from: .zero, operation: .sourceOver, fraction: 1)
            ctx.rotate(by: CGFloat(-angle * .pi / 180))
            ctx.translateBy(x: -fanBox / 2, y: -rect.midY)
            NSColor.labelColor.withAlphaComponent(dimmed ? 0.55 : 1).set()
            NSRect(x: 0, y: 0, width: fanBox, height: fanBox).fill(using: .sourceIn)
            ctx.endTransparencyLayer()
            ctx.restoreGState()

            // Air-quality dot: a plain flat circle.
            guard let tint else { return true }
            tint.setFill()
            NSBezierPath(ovalIn: NSRect(x: fanBox + gap, y: rect.midY - dot / 2, width: dot, height: dot)).fill()
            return true
        }
        // With no dot the icon stays a template so macOS styles it like other menu-bar icons.
        // With a dot it can't be a template (macOS would strip the colour), so the fan is
        // drawn in labelColor, which follows a light or dark menu bar.
        img.isTemplate = (tint == nil)
        return img
    }
}
