import SwiftUI

private let accentBlue = Color(red: 0.16, green: 0.47, blue: 1.0)

struct MenuView: View {
    @ObservedObject var model: RouterModel
    var close: () -> Void = {}
    @State private var showAllDevices = false

    var body: some View {
        VStack(spacing: 12) {
            Hero(model: model)
            if let s = model.status {
                HStack(spacing: 10) {
                    vpnTile(s)
                    tailscaleTile(s)
                }
                internetCard(s)
                SpeedTestCard(model: model, vpnConnected: s.vpn.state == "connected")
                devicesCard(s)
                routerCard(s)
            }
            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    // MARK: Tiles

    private func vpnTile(_ s: RouterStatus) -> some View {
        let on = s.vpn.wanted
        let subtitle: String = {
            switch s.vpn.state {
            case "connected": return s.vpn.location.split(separator: ",").last.map(String.init) ?? "Connected"
            case "connecting": return "Connecting…"
            default: return "Off"
            }
        }()
        return Tile(symbol: s.vpn.state == "connected" ? "lock.shield.fill" : "lock.shield",
                    title: "VPN", subtitle: subtitle,
                    active: on, tint: accentBlue,
                    busy: model.busyAction?.hasPrefix("VPN") == true) {
            model.perform(on ? "vpn-off" : "vpn-on", label: on ? "VPN off" : "VPN on")
        }
        .help(on ? "Turn the VPN off" : "Turn the VPN on")
    }

    private func tailscaleTile(_ s: RouterStatus) -> some View {
        let ok = s.tailscale.installed && s.tailscale.running && s.tailscale.health == "ok"
        let subtitle = !s.tailscale.installed ? "Not set up"
            : ok ? s.tailscale.ip
            : s.tailscale.running ? "Not connected" : "Not running"
        return Tile(symbol: "point.3.connected.trianglepath.dotted",
                    title: "Tailscale", subtitle: subtitle,
                    active: ok, tint: ok ? .green : .orange,
                    warning: s.tailscale.installed && !ok,
                    busy: model.busyAction?.hasPrefix("Tailscale") == true) {
            model.perform("tailscale-restart", label: "Tailscale restart")
        }
        .help("Restart Tailscale on the router")
    }

    // MARK: Cards

    private func internetCard(_ s: RouterStatus) -> some View {
        let u = s.upstream
        let symbol = !s.internet ? "wifi.slash"
            : u.type == "Wi-Fi" ? "wifi" : u.type == "Ethernet" ? "cable.connector" : "antenna.radiowaves.left.and.right"
        return Card {
            HStack(spacing: 12) {
                IconBadge(symbol: symbol, tint: s.internet ? accentBlue : .red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.internet ? (u.ssid.isEmpty ? (u.type.isEmpty ? "Internet" : u.type) : u.ssid) : "No internet")
                        .font(.system(size: 13, weight: .semibold))
                    Text(s.internet ? [u.ssid.isEmpty ? "" : u.type, u.gateway.isEmpty ? "" : "via \(u.gateway)"]
                            .filter { !$0.isEmpty }.joined(separator: " · ")
                         : "Upstream connection is down")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if let dbm = Int(u.signal_dbm) { SignalBars(dbm: dbm) }
            }
        }
    }

    private func devicesCard(_ s: RouterStatus) -> some View {
        let sorted = s.devices.sorted { ($0.online ? 0 : 1, $0.displayName.lowercased()) < ($1.online ? 0 : 1, $1.displayName.lowercased()) }
        let online = sorted.filter(\.online)
        let shown = Array((showAllDevices ? sorted : online).prefix(10))
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Devices").font(.system(size: 13, weight: .semibold))
                    Text("\(online.count)")
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(accentBlue.opacity(0.18)))
                        .foregroundStyle(accentBlue)
                    Spacer()
                    if sorted.count > online.count {
                        Button(showAllDevices ? "Online only" : "All \(sorted.count)") {
                            withAnimation(.easeInOut(duration: 0.2)) { showAllDevices.toggle() }
                        }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if shown.isEmpty {
                    Text("No devices online").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(shown) { d in
                    HStack(spacing: 10) {
                        Image(systemName: deviceSymbol(d.name))
                            .font(.system(size: 13))
                            .foregroundStyle(d.online ? .primary : .tertiary)
                            .frame(width: 18)
                        Text(d.displayName).font(.system(size: 12)).lineLimit(1)
                            .foregroundStyle(d.online ? .primary : .secondary)
                        Spacer()
                        Text(d.ip).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        Circle().fill(d.online ? Color.green : Color.secondary.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }
            }
        }
    }

    private func deviceSymbol(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("iphone") || n.contains("phone") || n.contains("pixel") || n.contains("galaxy") { return "iphone" }
        if n.contains("ipad") || n.contains("tab") { return "ipad" }
        if n.contains("mac") || n.contains("book") || n.contains("laptop") { return "laptopcomputer" }
        if n.contains("tv") || n.contains("roku") || n.contains("chromecast") || n.contains("fire") { return "tv" }
        if n.contains("watch") { return "applewatch" }
        if n.contains("ps") || n.contains("xbox") || n.contains("switch") || n.contains("steam") { return "gamecontroller" }
        if n.contains("print") { return "printer" }
        if n.contains("pc") || n.contains("desktop") || n.contains("bazzite") || n.contains("linux") { return "desktopcomputer" }
        return "circle.dotted"
    }

    private func routerCard(_ s: RouterStatus) -> some View {
        let memFree = s.mem_avail_kb / 1024
        let memPct = Double(s.mem_total_kb - s.mem_avail_kb) / Double(max(s.mem_total_kb, 1))
        return Card {
            VStack(spacing: 10) {
                HStack(spacing: 0) {
                    Stat(value: uptimeText(s.uptime), label: "Uptime")
                    Divider().frame(height: 26)
                    Stat(value: "\(memFree) MB", label: "Memory free",
                         tint: memFree < 12 ? .orange : nil, fill: memPct)
                    Divider().frame(height: 26)
                    Stat(value: "\(s.disk_free_kb / 1024) MB", label: "Storage free")
                    Divider().frame(height: 26)
                    Stat(value: s.load, label: "Load")
                }
                if !s.reboots.last.isEmpty {
                    let r = restartInfo(s.reboots.last)
                    HStack(spacing: 6) {
                        Image(systemName: r.symbol).foregroundStyle(r.color)
                        Text(r.text)
                        Spacer()
                        if s.reboots.unexpected > 0 {
                            Text("\(s.reboots.unexpected) problem restart\(s.reboots.unexpected == 1 ? "" : "s") logged")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 11))
                    .help(s.reboots.last)
                }
            }
        }
    }

    /// Label for the last restart, from the router's reboot log entry.
    private func restartInfo(_ entry: String) -> (text: String, symbol: String, color: Color) {
        if entry.contains("PROBLEM") { return ("Last restart: froze or crashed", "exclamationmark.circle.fill", .orange) }
        if entry.contains("UPDATE") { return ("Last restart: firmware update", "arrow.down.circle.fill", .blue) }
        if entry.contains("UNPLUGGED") { return ("Last restart: plugged in", "powerplug.fill", .secondary) }
        return ("Last restart: clean reboot", "checkmark.circle.fill", .green)
    }

    private func uptimeText(_ secs: Int) -> String {
        let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 4) {
            FooterButton(symbol: "safari", label: "Dashboard") { model.openDashboard(); close() }
            FooterButton(symbol: "power", label: "Reboot") { close(); model.confirmReboot() }
                .disabled(!model.reachable || model.busyAction != nil)
            FooterButton(symbol: "gearshape", label: "Settings") { SettingsMenu.show(model: model) }
        }
        .padding(.top, 2)
    }
}

// MARK: - Hero (status + animated LED)

private struct Hero: View {
    @ObservedObject var model: RouterModel

    var body: some View {
        HStack(spacing: 10) {
            Router3DView(state: model.reachable ? model.led : nil)
                .frame(width: 112, height: 84)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.reachable ? (model.led?.title ?? "Connecting…") : "Router unreachable")
                    .font(.system(size: 16, weight: .semibold))
                HStack(spacing: 6) {
                    if model.reachable, let led = model.led {
                        Text(led.ledDescription.replacingOccurrences(of: "LED: ", with: ""))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(model.lastError ?? "Checking…").lineLimit(1).foregroundStyle(.secondary)
                    }
                    if let r = model.route, model.reachable {
                        Label(r.rawValue, systemImage: r == .local ? "wifi" : "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.primary.opacity(0.08)))
                    }
                }
                .font(.system(size: 11))
            }
            Spacer(minLength: 0)
            Button { model.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Refresh now")
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}

// MARK: - Building blocks

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.06)))
    }
}

private struct Tile: View {
    let symbol: String
    let title: String
    let subtitle: String
    let active: Bool
    let tint: Color
    var warning = false
    var busy = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(active ? tint : (warning ? Color.orange.opacity(0.9) : Color.primary.opacity(0.1)))
                    if busy {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(active || warning ? .white : .primary)
                    }
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.primary.opacity(hover ? 0.09 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .onHover { hover = $0 }
    }
}

private struct IconBadge: View {
    let symbol: String
    let tint: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(Circle().fill(tint.opacity(0.15)))
    }
}

private struct SignalBars: View {
    let dbm: Int
    var bars: Int { dbm >= -55 ? 4 : dbm >= -67 ? 3 : dbm >= -75 ? 2 : 1 }
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i <= bars ? Color.primary : Color.primary.opacity(0.15))
                    .frame(width: 3, height: CGFloat(3 + i * 3))
            }
        }
        .help("\(dbm) dBm")
    }
}

private struct Stat: View {
    let value: String
    let label: String
    var tint: Color? = nil
    var fill: Double? = nil
    var body: some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(tint ?? .primary)
            Text(label).font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FooterButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 14))
                Text(label).font(.system(size: 10))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(hover ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hover = $0 }
    }
}
