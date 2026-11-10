import AppKit

/// The Settings pop-up (a standard Mac menu at the pointer).
@MainActor
final class SettingsMenu: NSObject {
    private static let shared = SettingsMenu()
    private weak var model: RouterModel?

    static func show(model: RouterModel) {
        shared.model = model
        let menu = NSMenu()
        menu.autoenablesItems = false

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = model.launchAtLogin ? .on : .off
        let ts = NSMenuItem(title: "Connect over Tailscale Only", action: #selector(toggleTailscale), keyEquivalent: "")
        ts.state = model.tailscaleOnly ? .on : .off
        let quit = NSMenuItem(title: "Quit RouterBar", action: #selector(quit), keyEquivalent: "q")
        for item in [login, ts, quit] { item.target = shared }

        menu.addItem(login)
        menu.addItem(ts)
        menu.addItem(.separator())
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func toggleLogin() { model?.launchAtLogin.toggle() }
    @objc private func toggleTailscale() { model?.tailscaleOnly.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }
}
