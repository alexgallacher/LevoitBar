import AppKit
import SwiftUI

@main
struct LevoitBarApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Menu-bar only: no Dock icon, even when launched with `swift run`.
        NSApplication.shared.setActivationPolicy(.accessory)
        MainActor.assumeIsolated { Snapshot.runIfRequested() }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(model)
        } label: {
            MenuBarLabel(icon: model.menuIcon)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var icon: MenuIconAnimator

    var body: some View {
        Image(nsImage: icon.image)
    }
}

/// Spins the menu-bar fan while a purifier is running, faster at higher speeds.
@MainActor
final class MenuIconAnimator: ObservableObject {
    @Published private(set) var image: NSImage

    private var angle: CGFloat = 0
    private var degreesPerTick: CGFloat = 0
    private var timer: Timer?
    /// Air-quality colour; nil means a plain monochrome menu-bar icon.
    private var tint: NSColor?
    private static let symbol: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let base = NSImage(systemSymbolName: "fan", accessibilityDescription: "LevoitBar")
            ?? NSImage(systemSymbolName: "wind", accessibilityDescription: "LevoitBar")!
        return base.withSymbolConfiguration(config) ?? base
    }()

    init() {
        image = Self.render(angle: 0, dimmed: true, tint: nil)
    }

    func update(running: Bool, speed: Int, airQuality: Int?) {
        if let rgb = PurifierStatus.airQualityRGB(airQuality) {
            tint = NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
        } else {
            tint = nil
        }
        if running {
            degreesPerTick = 6 + CGFloat(speed) * 5
            if timer == nil {
                let t = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
        } else {
            timer?.invalidate()
            timer = nil
            image = Self.render(angle: angle, dimmed: true, tint: tint)
        }
    }

    private func tick() {
        angle = (angle - degreesPerTick).truncatingRemainder(dividingBy: 360)
        image = Self.render(angle: angle, dimmed: false, tint: tint)
    }

    private static func render(angle: CGFloat, dimmed: Bool, tint: NSColor?) -> NSImage {
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
            ctx.rotate(by: angle * .pi / 180)
            let s = symbol.size
            symbol.draw(in: NSRect(x: -s.width / 2, y: -s.height / 2, width: s.width, height: s.height),
                        from: .zero, operation: .sourceOver, fraction: 1)
            ctx.rotate(by: -angle * .pi / 180)
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
