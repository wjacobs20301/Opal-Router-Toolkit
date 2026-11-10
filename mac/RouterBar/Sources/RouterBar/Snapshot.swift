import SwiftUI
import AppKit

/// Developer aid: `RouterBar --snapshot <dir>` renders the menu (live data, light + dark)
/// and the menu bar icon in every LED state to PNGs, then quits.
@MainActor
enum Snapshot {
    static func runIfRequested(model: RouterModel) -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        Task { @MainActor in
            for _ in 0..<40 where model.status == nil { try? await Task.sleep(nanoseconds: 500_000_000) }
            for (name, scheme) in [("menu-light", ColorScheme.light), ("menu-dark", .dark)] {
                let view = MenuView(model: model)
                    .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96))
                    .environment(\.colorScheme, scheme)
                let r = ImageRenderer(content: view)
                r.scale = 2
                if let img = r.nsImage { write(img, to: dir.appendingPathComponent("\(name).png")) }
            }
            // Menu bar icons for each state, on light and dark bars.
            let states: [LEDState] = [.online, .vpnConnected, .vpnConnecting, .noInternet, .tailscaleDown]
            // 3D router in each LED state, a few angles.
            for (name, scheme) in [("router-light", ColorScheme.light), ("router-dark", .dark)] {
                let sheet = VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        ForEach(Array(states.enumerated()), id: \.offset) { _, s in
                            Router3DView(state: s, sway: false, fixedTime: 0.6).frame(width: 140, height: 105)
                        }
                    }
                    ForEach([[-0.6, -1.3, -1.9, -2.4, -3.0], [0.4, 1.0, 1.6, 2.5, 3.6]], id: \.self) { row in
                        HStack(spacing: 4) {
                            ForEach(row, id: \.self) { y in
                                Router3DView(state: .vpnConnected, sway: false, fixedTime: 0.1, yawOffset: y)
                                    .frame(width: 140, height: 105)
                            }
                        }
                    }
                }
                .padding(8)
                .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96))
                .environment(\.colorScheme, scheme)
                let r = ImageRenderer(content: sheet)
                r.scale = 2
                if let img = r.nsImage { write(img, to: dir.appendingPathComponent("\(name).png")) }
            }
            for (bar, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let strip = NSImage(size: NSSize(width: 40 * states.count + 20, height: 30))
                NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                    strip.lockFocus()
                    (bar == "dark" ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                    NSRect(origin: .zero, size: strip.size).fill()
                    for (k, s) in states.enumerated() {
                        let icon = MenuBarIcon.image(state: s, reachable: true, frame: s.frame(at: 0.1))
                        icon.draw(in: NSRect(x: 12 + CGFloat(k) * 40, y: 6, width: icon.size.width, height: icon.size.height))
                    }
                    strip.unlockFocus()
                }
                write(strip, to: dir.appendingPathComponent("icons-\(bar).png"))
            }
            NSApp.terminate(nil)
        }
        return true
    }

    private static func write(_ img: NSImage, to url: URL) {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
