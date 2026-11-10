import Foundation
import AppKit
import UserNotifications

@MainActor
final class RouterModel: ObservableObject {
    @Published private(set) var status: RouterStatus?
    @Published private(set) var route: SSH.Route?
    @Published private(set) var lastError: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var busyAction: String?
    @Published private(set) var vpnChangedFromApp = false
    @Published private(set) var speedResults: [String: SpeedResult] = {
        guard let d = UserDefaults.standard.data(forKey: "speedResults"),
              let r = try? JSONDecoder().decode([String: SpeedResult].self, from: d) else { return [:] }
        return r
    }()
    @Published private(set) var speedTestRunning: String?     // "direct" | "vpn"
    @Published private(set) var speedTestStarted: Date?
    @Published var tailscaleOnly: Bool = UserDefaults.standard.bool(forKey: "tailscaleOnly") {
        didSet { UserDefaults.standard.set(tailscaleOnly, forKey: "tailscaleOnly"); route = nil; refresh() }
    }
    private var failures = 0
    @Published var launchAtLogin: Bool = LoginItem.isEnabled {
        didSet { LoginItem.set(launchAtLogin) }
    }

    var led: LEDState? { status.map(LEDState.init) }
    var reachable: Bool { status != nil && lastError == nil }

    private var timer: Timer?
    private var knownDevices: Set<String>
    private var refreshing = false

    init() {
        knownDevices = Set(UserDefaults.standard.stringArray(forKey: "knownDevices") ?? [])
        if CommandLine.arguments.contains("--demo") { loadDemo(); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            let result = await SSH.run("/etc/router-app/status.sh", preferred: route, tailscaleOnly: tailscaleOnly)
            refreshing = false
            switch result {
            case .success(let (route, data)):
                do {
                    let new = try JSONDecoder().decode(RouterStatus.self, from: data)
                    if let old = status { notifyChanges(from: old, to: new) }
                    else { seedDevices(new) }
                    failures = 0
                    status = new
                    self.route = route
                    lastError = nil
                    lastUpdated = Date()
                } catch {
                    lastError = "Unexpected reply from router"
                }
            case .failure(let f):
                // No notification: on a travel router, unreachable usually just means unplugged.
                failures += 1
                lastError = f.message.isEmpty ? "Router unreachable" : f.message
            }
        }
    }

    /// Made-up data for screenshots (`--demo`): documentation IP ranges, sample devices.
    private func loadDemo() {
        status = RouterStatus(
            uptime: 3 * 3600 + 25 * 60, load: "0.84", mem_total_kb: 118700, mem_avail_kb: 31800,
            swap_total_kb: 58364, swap_free_kb: 39100, disk_free_kb: 35800, lan_ip: "192.168.8.1",
            internet: true,
            upstream: .init(type: "Wi-Fi", device: "sta0", ssid: "Hotel Guest", signal_dbm: "-61", gateway: "192.0.2.1"),
            vpn: .init(wanted: true, state: "connected", server: "vpn.example.net", location: "Canada,Vancouver"),
            tailscale: .init(installed: true, running: true, health: "ok", ip: "100.64.0.12"),
            reboots: .init(last: "boot #12: UNPLUGGED - router was healthy right before", unexpected: 0),
            devices: [
                .init(mac: "02:00:00:00:00:01", ip: "192.168.8.120", name: "MacBook-Pro", online: true, lease_expires: 0),
                .init(mac: "02:00:00:00:00:02", ip: "192.168.8.134", name: "iPhone", online: true, lease_expires: 0),
                .init(mac: "02:00:00:00:00:03", ip: "192.168.8.151", name: "Living-Room-TV", online: true, lease_expires: 0),
                .init(mac: "02:00:00:00:00:04", ip: "192.168.8.162", name: "iPad", online: false, lease_expires: 0),
            ])
        speedResults = ["direct": SpeedResult(path: "direct", server: "YVR", ping_ms: 21, jitter_ms: 3,
                                              download_mbps: 84.6, upload_mbps: 38.9, cpu_download: 71,
                                              cpu_upload: 64, error: nil, date: Date().addingTimeInterval(-600))]
        route = .local
        lastUpdated = Date()
    }

    // MARK: Actions

    /// The only actions the router accepts (same list as /etc/router-app/action.sh).
    static let allowedActions: Set<String> = ["vpn-on", "vpn-off", "tailscale-restart", "reboot"]

    func perform(_ action: String, label: String) {
        guard Self.allowedActions.contains(action) else { return }
        busyAction = label
        if action.hasPrefix("vpn-") { vpnChangedFromApp = true }
        Task {
            let r = await SSH.run("/etc/router-app/action.sh \(action)", preferred: route, tailscaleOnly: tailscaleOnly)
            busyAction = nil
            if case .failure(let f) = r { notify("\(label) failed", f.message) }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            refresh()
        }
    }

    func runSpeedTest(_ path: String) {
        // Only these two values ever reach the router's command line.
        guard path == "direct" || path == "vpn", speedTestRunning == nil else { return }
        speedTestRunning = path
        speedTestStarted = Date()
        Task {
            let r = await SSH.run("/etc/router-app/action.sh speedtest-\(path)", preferred: route,
                                  tailscaleOnly: tailscaleOnly, timeout: 75)
            var result: SpeedResult
            switch r {
            case .success(let (_, data)):
                result = (try? JSONDecoder().decode(SpeedResult.self, from: data))
                    ?? SpeedResult(error: "Unexpected reply from router")
            case .failure(let f):
                result = SpeedResult(error: f.message.isEmpty ? "Router unreachable" : f.message)
            }
            result.date = Date()
            if result.error == nil || speedResults[path] == nil { speedResults[path] = result }
            else { speedResults[path]?.error = result.error }
            if let d = try? JSONEncoder().encode(speedResults) { UserDefaults.standard.set(d, forKey: "speedResults") }
            speedTestRunning = nil
            speedTestStarted = nil
        }
    }

    func confirmReboot() {
        let a = NSAlert()
        a.messageText = "Reboot the router?"
        a.informativeText = "Everything on its network loses internet for about 2 minutes."
        a.addButton(withTitle: "Reboot")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { perform("reboot", label: "Reboot") }
    }

    func openDashboard() {
        // Only open a real IPv4 address reported by the router (never an arbitrary URL).
        var ip = status?.lan_ip ?? ""
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        let isIPv4 = parts.count == 4 && parts.allSatisfy { p in
            p.count <= 3 && !p.isEmpty && p.allSatisfy(\.isNumber) && (Int(p) ?? 256) <= 255 }
        if !isIPv4 { ip = "192.168.8.1" }   // GL.iNet default
        if let url = URL(string: "http://\(ip)") { NSWorkspace.shared.open(url) }
    }

    // MARK: Notifications

    private func notifyChanges(from old: RouterStatus, to new: RouterStatus) {
        // Restarts: only real problems (a freeze or crash) are worth a notification.
        // Being unplugged and plugged back in is normal for a travel router.
        if new.reboots.unexpected > old.reboots.unexpected {
            notify("Router had a problem and restarted",
                   "It likely froze or crashed. Details are in the reboot log.")
        }
        // Just started up (e.g. plugged in somewhere new): give it 3 minutes to connect
        // before reporting internet, VPN, or Tailscale changes.
        let settling = new.uptime < 180 || new.uptime < old.uptime
        if !settling {
            notifyConnectionChanges(from: old, to: new)
        }
        for d in new.devices where !knownDevices.contains(d.mac) {
            notify("New device joined", "\(d.displayName) · \(d.ip)")
            knownDevices.insert(d.mac)
        }
        UserDefaults.standard.set(Array(knownDevices), forKey: "knownDevices")
    }

    private func notifyConnectionChanges(from old: RouterStatus, to new: RouterStatus) {
        if old.internet && !new.internet { notify("Router lost internet", "The upstream connection is down.") }
        if !old.internet && new.internet { notify("Router internet is back", new.upstream.type) }
        if old.vpn.state == "connected" && new.vpn.state != "connected" && new.vpn.wanted {
            notify("VPN disconnected", "The VPN is switched on but no longer connected.")
        }
        if old.vpn.state != "connected" && new.vpn.state == "connected" {
            notify("VPN connected", [new.vpn.server, new.vpn.location].filter { !$0.isEmpty }.joined(separator: " · "))
        }
        if old.tailscale.health != "bad" && new.tailscale.health == "bad" && new.internet {
            notify("Tailscale not connected", "The router's Tailscale connection is down.")
        }
        if old.tailscale.health == "bad" && new.tailscale.health == "ok" {
            notify("Tailscale connected", new.tailscale.ip)
        }
    }

    private func seedDevices(_ s: RouterStatus) {
        // First run: remember current devices without notifying about each one.
        if knownDevices.isEmpty {
            knownDevices = Set(s.devices.map(\.mac))
            UserDefaults.standard.set(Array(knownDevices), forKey: "knownDevices")
        }
    }

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

/// Launch at login via a per-user LaunchAgent (works for a locally built, unsigned app).
enum LoginItem {
    static let label = "local.routerbar"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func set(_ on: Bool) {
        if on {
            let exe = Bundle.main.executablePath ?? "/Applications/RouterBar.app/Contents/MacOS/RouterBar"
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [exe],
                "RunAtLoad": true,
                "LimitLoadToSessionType": "Aqua",
            ]
            try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: plistURL)
            }
        } else {
            try? FileManager.default.removeItem(at: plistURL)
        }
    }
}
