import SwiftUI
import AppKit
import Combine

/// Plain AppKit startup: a menu bar app with no windows of its own. (A SwiftUI `App` must
/// declare a scene, and its placeholder Settings window could pop up empty when the app was
/// reopened or ⌘, was pressed.)
@main
enum RouterBarMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// Menu bar item (AppKit, so the icon keeps its color and can animate) + a popover with the SwiftUI menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private let model = RouterModel()
    private let animator = LEDAnimator()
    private var subs = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ n: Notification) {
        if Snapshot.runIfRequested(model: model) { return }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.image = animator.icon

        let host = NSHostingController(rootView: MenuView(model: model, close: { [weak self] in
            self?.popover.performClose(nil)
        }))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true

        animator.$icon.sink { [weak self] img in self?.item.button?.image = img }.store(in: &subs)
        model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.animator.update(state: self.model.led, reachable: self.model.reachable)
                self.item.button?.toolTip = self.model.reachable ? (self.model.led?.title ?? "") : "Router unreachable"
            }
        }.store(in: &subs)
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
