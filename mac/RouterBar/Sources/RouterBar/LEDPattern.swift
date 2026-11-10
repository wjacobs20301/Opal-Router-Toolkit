import AppKit
import SwiftUI

/// One shared clock for every LED animation in the app (menu bar icon and 3D model).
enum LEDClock {
    static func at(_ date: Date) -> TimeInterval { date.timeIntervalSinceReferenceDate }
    static var now: TimeInterval { at(Date()) }
}

/// The router LED's colors and timing, reproduced for the menu bar icon and the menu's "LED".
enum LEDColor: Equatable { case blue, white, off }

struct LEDFrame: Equatable {
    var color: LEDColor
    var level: Double      // 0...1 brightness
}

extension LEDState {
    /// Whether the pattern changes over time (needs animation frames).
    var animated: Bool {
        switch self {
        case .vpnConnected, .online: return false
        default: return true
        }
    }

    /// The LED at time `t` (seconds), matching the router's own patterns.
    func frame(at t: TimeInterval) -> LEDFrame {
        switch self {
        case .vpnConnected:
            return LEDFrame(color: .blue, level: 1)
        case .online:
            return LEDFrame(color: .white, level: 1)
        case .vpnConnecting:                       // blue blink, 0.512 s period, 50%
            let p = t.truncatingRemainder(dividingBy: 0.512)
            return LEDFrame(color: .blue, level: p < 0.256 ? 1 : 0.12)
        case .noInternet:                          // blue breathing, ~4 s
            let x = (sin(t * 2 * .pi / 4.096) + 1) / 2
            return LEDFrame(color: .blue, level: 0.15 + 0.85 * x)
        case .tailscaleDown:                       // white 0.35 · off 0.15 · blue 0.35 · off 0.15
            let p = t.truncatingRemainder(dividingBy: 1.0)
            if p < 0.35 { return LEDFrame(color: .white, level: 1) }
            if p < 0.5 { return LEDFrame(color: .off, level: 0) }
            if p < 0.85 { return LEDFrame(color: .blue, level: 1) }
            return LEDFrame(color: .off, level: 0)
        }
    }
}

/// Draws the menu bar icon: the router symbol tinted like the LED.
/// "White" uses the menu bar's text color so it's visible in light and dark mode.
enum MenuBarIcon {
    static let symbolConfig = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)

    static func image(state: LEDState?, reachable: Bool, frame: LEDFrame?) -> NSImage {
        let name = reachable ? (state.map(symbolName) ?? "wifi.router") : "wifi.router"
        let base = NSImage(systemSymbolName: name, accessibilityDescription: "Router")!
            .withSymbolConfiguration(symbolConfig)!
        let size = base.size

        let img = NSImage(size: size, flipped: false) { rect in
            let tint: NSColor
            if !reachable {
                tint = NSColor.labelColor.withAlphaComponent(0.35)
            } else if let f = frame {
                switch f.color {
                case .blue: tint = NSColor(calibratedRed: 0.20, green: 0.52, blue: 1.0, alpha: 1)
                    .withAlphaComponent(max(f.level, 0.25))
                case .white: tint = NSColor.labelColor.withAlphaComponent(max(f.level, 0.25))
                case .off: tint = NSColor.labelColor.withAlphaComponent(0.25)
                }
            } else {
                tint = .labelColor
            }
            base.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        img.isTemplate = false
        return img
    }

    private static func symbolName(_ s: LEDState) -> String {
        switch s {
        case .vpnConnected, .vpnConnecting: return "wifi.router.fill"
        case .noInternet: return "wifi.exclamationmark"
        default: return "wifi.router"
        }
    }
}

/// Drives animation frames for the menu bar icon (only while the pattern is animated).
@MainActor
final class LEDAnimator: ObservableObject {
    @Published private(set) var icon: NSImage = MenuBarIcon.image(state: nil, reachable: false, frame: nil)
    private var timer: Timer?
    private var state: LEDState?
    private var reachable = false

    func update(state: LEDState?, reachable: Bool) {
        guard state != self.state || reachable != self.reachable else { return }
        self.state = state
        self.reachable = reachable
        timer?.invalidate(); timer = nil
        render()
        if reachable, let s = state, s.animated {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.render() }
            }
        }
    }

    private func render() {
        // Same clock as the menu's 3D model, so both blink in step.
        let t = LEDClock.now
        icon = MenuBarIcon.image(state: state, reachable: reachable, frame: state?.frame(at: t))
    }
}
