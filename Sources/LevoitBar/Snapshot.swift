import AppKit
import SwiftUI

/// `LevoitBar --snapshot <file.png>` renders the panel with sample data and exits.
/// Handy for checking the design without signing in.
enum Snapshot {
    /// True while rendering a snapshot (menus can't be drawn offscreen).
    static var isActive = false

    @MainActor
    static func runIfRequested() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--icons"), i + 1 < args.count {
            renderIcons(to: args[i + 1])
        }
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        isActive = true
        let model = AppModel(demo: true)
        let view = ContentView().environmentObject(model)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage,
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: args[i + 1]))
        }
        exit(0)
    }

    /// Menu-bar icon for each air-quality level, on light and dark strips.
    @MainActor
    private static func renderIcons(to path: String) {
        let levels: [Int?] = [1, 2, 3, 4, nil]
        let scale: CGFloat = 4
        let cell: CGFloat = 34
        let out = NSImage(size: NSSize(width: cell * CGFloat(levels.count) * scale, height: cell * 2 * scale), flipped: false) { rect in
            NSColor(white: 0.93, alpha: 1).setFill(); NSRect(x: 0, y: rect.midY, width: rect.width, height: rect.height / 2).fill()
            NSColor(white: 0.15, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: rect.width, height: rect.height / 2).fill()
            for (i, level) in levels.enumerated() {
                let animator = MenuIconAnimator()
                animator.update(running: false, speed: 0, airQuality: level)
                animator.update(running: false, speed: 0, airQuality: level)
                let img = animator.image
                for row in 0..<2 {
                    let r = NSRect(x: (CGFloat(i) * cell + 4) * scale, y: (CGFloat(row) * cell + 8) * scale,
                                   width: img.size.width * scale, height: img.size.height * scale)
                    if img.isTemplate {
                        let tinted = NSImage(size: img.size, flipped: false) { rr in
                            img.draw(in: rr)
                            (row == 0 ? NSColor.white : NSColor.black).set()
                            rr.fill(using: .sourceIn)
                            return true
                        }
                        tinted.draw(in: r)
                    } else {
                        NSAppearance(named: row == 0 ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                            img.draw(in: r)
                        }
                    }
                }
            }
            return true
        }
        if let tiff = out.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}

extension AppModel {
    convenience init(demo: Bool) {
        self.init(noAutoLogin: ())
        let device = VeSyncDevice(cid: "demo", name: "Living Room", deviceType: "Core400S",
                                  configModule: "", connectionStatus: "online", deviceStatus: "on")
        let status = PurifierStatus(isOn: true, mode: "manual", fanLevel: 3, manualLevel: 3,
                                    filterLife: 72, airQualityLevel: 1, pm25: 4,
                                    displayOn: true, childLock: false)
        loadDemo([Purifier(device: device, caps: PurifierCapabilities.forDeviceType("Core400S")!, status: status)])
    }
}
