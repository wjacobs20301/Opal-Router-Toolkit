import SwiftUI

private let blue = Color(red: 0.16, green: 0.47, blue: 1.0)

/// The "Connections" window: load-balanced connections with live bandwidth and per-connection
/// tests, plus tests run from this Mac.
struct ConnectionsView: View {
    @ObservedObject var model: ConnectionsModel
    @ObservedObject var router: RouterModel
    /// false for snapshots (ImageRenderer can't draw scroll views)
    var scrolls = true

    var body: some View {
        Group {
            if scrolls { ScrollView { content } } else { content }
        }
        .frame(minWidth: 640, idealWidth: 700, minHeight: 560, idealHeight: 760)
        .onAppear { if scrolls { model.startPolling() } }
        .onDisappear { if scrolls { model.stopPolling() } }
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let snap = model.snapshot {
                    ForEach(snap.interfaces) { i in ConnectionCard(model: model, router: router, iface: i) }
                    routerPathsCard
                } else {
                    Text(model.lastError ?? "Loading connections…")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40)
                }
                sectionTitle("This Mac", subtitle: "Tests run from this Mac rather than the router")
                HStack(alignment: .top, spacing: 14) {
                    macInternetCard
                    macRouterCard
                }
            }
            .padding(22)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connections").font(.system(size: 22, weight: .bold))
                Text("Internet connections the router can use, with live traffic and tests")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if let mode = model.snapshot?.mode {
                Label(mode == "balance" ? "Load Balance" : "Failover",
                      systemImage: mode == "balance" ? "arrow.triangle.branch" : "arrow.uturn.right")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(blue.opacity(0.15)))
                    .foregroundStyle(blue)
                    .help("Set in the GL.iNet dashboard (Internet → Multi-WAN)")
            }
        }
    }

    private func sectionTitle(_ t: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.system(size: 15, weight: .semibold))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }

    // MARK: Router default route + VPN

    private var routerPathsCard: some View {
        let vpnUp = router.status?.vpn.state == "connected"
        return Panel {
            VStack(alignment: .leading, spacing: 10) {
                Text("From the router").font(.system(size: 13, weight: .semibold))
                PathTestRow(model: model, title: "Normal route", detail: "How the router's own traffic goes out",
                            symbol: "globe", path: "direct")
                Divider()
                PathTestRow(model: model, title: "Through the VPN",
                            detail: vpnUp ? (router.status?.vpn.server ?? "VPN") : "VPN isn't connected",
                            symbol: "lock.shield", path: "vpn", enabled: vpnUp)
            }
        }
    }

    // MARK: This Mac

    private var macInternetCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                Label("Mac → Internet", systemImage: "laptopcomputer").font(.system(size: 13, weight: .semibold))
                if let r = model.macInternet {
                    HStack(spacing: 0) {
                        Metric(value: r.downMbps, unit: "Mbit/s", label: "Download", symbol: "arrow.down.circle.fill", tint: .blue)
                        Metric(value: r.upMbps, unit: "Mbit/s", label: "Upload", symbol: "arrow.up.circle.fill", tint: .purple)
                        Metric(value: r.latencyMs, unit: "ms", label: "Latency", symbol: "timer", tint: .green, decimals: 0)
                    }
                    Text("Apple network test · \(r.date.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                } else {
                    Text(model.macInternetError ?? "Your Mac's full internet speed, using Apple's built-in network test (about 20 s).")
                        .font(.system(size: 11)).foregroundStyle(model.macInternetError == nil ? .secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                RunButton(title: model.macTest == "internet" ? "Testing…" : "Run Test",
                          running: model.macTest == "internet") { model.runMacInternet() }
                    .disabled(model.macTest != nil)
            }
        }
    }

    private var macRouterCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                Label("Mac → Router", systemImage: "wifi.router").font(.system(size: 13, weight: .semibold))
                if let r = model.macRouter {
                    if let e = r.error {
                        Text(e).font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    HStack(spacing: 0) {
                        Metric(value: r.downMbps, unit: "Mbit/s", label: "Download", symbol: "arrow.down.circle.fill", tint: .blue)
                        Metric(value: r.upMbps, unit: "Mbit/s", label: "Upload", symbol: "arrow.up.circle.fill", tint: .purple)
                        Metric(value: r.latencyMs, unit: "ms", label: "Latency", symbol: "timer", tint: .green, decimals: 1)
                    }
                    Text("Via \(r.via)\(r.lossPct.map { $0 > 0 ? " · \($0)% loss" : "" } ?? "") · \(r.date.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                } else {
                    Text("The link between this Mac and the router. Speeds are capped by the router's small CPU serving the test.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                RunButton(title: model.macTest == "router" ? "Testing…" : "Run Test",
                          running: model.macTest == "router") { model.runMacRouter() }
                    .disabled(model.macTest != nil)
            }
        }
    }
}

// MARK: - One load-balanced connection

private struct ConnectionCard: View {
    @ObservedObject var model: ConnectionsModel
    @ObservedObject var router: RouterModel
    let iface: WanSnapshot.Interface

    var body: some View {
        let samples = model.history[iface.name] ?? []
        let now = samples.last ?? RateSample(down: 0, up: 0)
        let path = "wan:\(iface.name)"
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(iface.up ? blue : Color.secondary)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill((iface.up ? blue : Color.secondary).opacity(0.14)))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(title).font(.system(size: 14, weight: .semibold))
                            badge
                        }
                        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if iface.up {
                        VStack(alignment: .trailing, spacing: 2) {
                            Rate(value: now.down, symbol: "arrow.down", tint: .blue)
                            Rate(value: now.up, symbol: "arrow.up", tint: .purple)
                        }
                    }
                }
                if iface.up {
                    Sparkline(samples: samples)
                        .frame(height: 54)
                    HStack(spacing: 8) {
                        TestButton(title: "Test Latency", symbol: "timer",
                                   running: model.runningTest == "latency:\(path)") { model.runLatency(path) }
                        TestButton(title: "Test Speed", symbol: "speedometer",
                                   running: model.runningTest == "speed:\(path)") { model.runSpeed(path) }
                        Spacer()
                    }
                    .disabled(model.runningTest != nil)
                    ResultsLine(latency: model.latency[path], speed: model.speed[path])
                }
            }
            .opacity(iface.up ? 1 : 0.65)
        }
    }

    private var symbol: String {
        switch iface.name {
        case "wan", "secondwan": return "cable.connector"
        case "wwan": return "wifi"
        case "tethering": return "iphone"
        default: return "antenna.radiowaves.left.and.right"
        }
    }

    private var title: String {
        if iface.name == "wwan", iface.up, let ssid = router.status?.upstream.ssid, !ssid.isEmpty,
           router.status?.upstream.type == "Wi-Fi" {
            return "Repeater · \(ssid)"
        }
        return iface.type
    }

    private var detail: String {
        guard iface.up else { return iface.disabled ? "Turned off in load balancing" : "Not connected" }
        var parts = [iface.ip]
        if !iface.gateway.isEmpty { parts.append("via \(iface.gateway)") }
        if let s = model.share(of: iface) { parts.append("\(Int((s * 100).rounded()))% of new connections") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var badge: some View {
        let (text, color): (String, Color) = !iface.up ? ("Offline", .secondary)
            : iface.state == "ACTIVE" ? ("Active", .green) : ("Standby", .orange)
        Text(text).font(.system(size: 9.5, weight: .bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

// MARK: - Building blocks

private struct PathTestRow: View {
    @ObservedObject var model: ConnectionsModel
    let title: String
    let detail: String
    let symbol: String
    let path: String
    var enabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: symbol).foregroundStyle(blue).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5, weight: .medium))
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
                TestButton(title: "Latency", symbol: "timer", running: model.runningTest == "latency:\(path)") { model.runLatency(path) }
                TestButton(title: "Speed", symbol: "speedometer", running: model.runningTest == "speed:\(path)") { model.runSpeed(path) }
            }
            .disabled(model.runningTest != nil || !enabled)
            ResultsLine(latency: model.latency[path], speed: model.speed[path])
        }
        .opacity(enabled ? 1 : 0.6)
    }
}

private struct ResultsLine: View {
    let latency: LatencyResult?
    let speed: SpeedResult?

    var body: some View {
        let items = parts
        if !items.isEmpty {
            HStack(spacing: 14) {
                ForEach(items, id: \.0) { item in
                    HStack(spacing: 4) {
                        Image(systemName: item.1).foregroundStyle(item.3)
                        Text(item.2).monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11.5))
            if let s = speed, s.cpuLimited {
                Label("Router CPU maxed out during the speed test, so this connection may be faster",
                      systemImage: "cpu")
                    .font(.system(size: 10.5)).foregroundStyle(.orange)
            }
        }
    }

    private var parts: [(String, String, String, Color)] {
        var p: [(String, String, String, Color)] = []
        if let l = latency {
            if let e = l.error { p.append(("le", "exclamationmark.triangle", e, .orange)) }
            else {
                p.append(("lat", "timer", "\(l.avg_ms.map { String(format: "%.0f", $0) } ?? "–") ms", .green))
                p.append(("jit", "waveform.path", "±\(l.jitter_ms.map { String(format: "%.0f", $0) } ?? "–") ms", .secondary))
                p.append(("loss", "xmark.octagon", "\(l.loss_pct ?? 0)% loss", (l.loss_pct ?? 0) > 0 ? .orange : .secondary))
            }
        }
        if let s = speed {
            if let e = s.error { p.append(("se", "exclamationmark.triangle", e, .orange)) }
            else {
                p.append(("dn", "arrow.down.circle.fill", "\(s.download_mbps.map { String(format: "%.1f", $0) } ?? "–") Mbit/s", .blue))
                p.append(("up", "arrow.up.circle.fill", "\(s.upload_mbps.map { String(format: "%.1f", $0) } ?? "–") Mbit/s", .purple))
            }
        }
        return p
    }
}

private struct Rate: View {
    let value: Double
    let symbol: String
    let tint: Color
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
            Text(value >= 10 ? String(format: "%.0f", value) : String(format: "%.1f", value))
                .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
            Text("Mbit/s").font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
    }
}

/// Last 60 samples: download filled, upload as a dashed line.
private struct Sparkline: View {
    let samples: [RateSample]
    private let n = 60

    private var peak: Double { max(samples.map { max($0.down, $0.up) }.max() ?? 0, 1) }

    private func point(_ i: Int, _ v: Double, _ size: CGSize) -> CGPoint {
        let step = size.width / CGFloat(n - 1)
        let offset = n - samples.count
        return CGPoint(x: CGFloat(i + offset) * step, y: size.height * (1 - CGFloat(v / peak) * 0.92))
    }

    private func line(_ size: CGSize, _ value: (RateSample) -> Double) -> Path {
        Path { p in
            for (i, s) in samples.enumerated() {
                let pt = point(i, value(s), size)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
    }

    private func area(_ size: CGSize) -> Path {
        Path { p in
            guard let first = samples.first else { return }
            p.move(to: CGPoint(x: point(0, first.down, size).x, y: size.height))
            for (i, s) in samples.enumerated() { p.addLine(to: point(i, s.down, size)) }
            p.addLine(to: CGPoint(x: size.width, y: size.height))
            p.closeSubpath()
        }
    }

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04))
                if samples.count > 1 {
                    area(g.size).fill(LinearGradient(colors: [blue.opacity(0.35), blue.opacity(0.05)],
                                                     startPoint: .top, endPoint: .bottom))
                    line(g.size) { $0.down }.stroke(blue, lineWidth: 1.5)
                    line(g.size) { $0.up }.stroke(Color.purple.opacity(0.8), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                }
                Text("peak \(peak >= 10 ? String(format: "%.0f", peak) : String(format: "%.1f", peak)) Mbit/s · last 2 min")
                    .font(.system(size: 9)).foregroundStyle(.secondary).padding(5)
            }
        }
    }
}

private struct Metric: View {
    let value: Double?
    let unit: String
    let label: String
    let symbol: String
    let tint: Color
    var decimals = 1
    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value.map { String(format: "%.\(decimals)f", $0) } ?? "–")
                    .font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            HStack(spacing: 3) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(label)
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct Panel<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

private struct TestButton: View {
    let title: String
    let symbol: String
    let running: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if running { ProgressView().controlSize(.mini) }
                else { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
                Text(running ? "Testing…" : title).font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(blue.opacity(hover ? 0.22 : 0.14)))
            .foregroundStyle(blue)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct RunButton: View {
    let title: String
    let running: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if running { ProgressView().controlSize(.small).tint(.white) }
                else { Image(systemName: "play.fill").font(.system(size: 10)) }
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(blue))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }
}
