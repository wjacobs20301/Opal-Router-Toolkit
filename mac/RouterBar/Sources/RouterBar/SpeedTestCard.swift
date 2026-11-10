import SwiftUI

/// Internet speed test run on the router (Cloudflare servers), direct or through the VPN.
struct SpeedTestCard: View {
    @ObservedObject var model: RouterModel
    let vpnConnected: Bool
    @AppStorage("speedTestPath") private var path = "direct"

    private var effectivePath: String { vpnConnected && path == "vpn" ? "vpn" : "direct" }
    private var result: SpeedResult? { model.speedResults[effectivePath] }
    private var running: Bool { model.speedTestRunning != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "speedometer")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.16, green: 0.47, blue: 1.0))
                Text("Speed Test").font(.system(size: 13, weight: .semibold))
                Spacer()
                if vpnConnected {
                    Segmented(selection: $path, options: [("direct", "Direct"), ("vpn", "Via VPN")])
                        .disabled(running)
                        .opacity(running ? 0.5 : 1)
                }
            }

            if running {
                runningView
            } else if let r = result, r.download_mbps != nil {
                resultView(r)
            } else {
                Text(result?.error ?? "Measures the router's own connection to the internet. Takes about 25 seconds.")
                    .font(.system(size: 11))
                    .foregroundStyle(result?.error != nil ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !running {
                RunButton(title: result == nil ? "Run Speed Test" : "Run Again") {
                    model.runSpeedTest(effectivePath)
                }
                .disabled(!model.reachable)
                .opacity(model.reachable ? 1 : 0.5)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.06)))
    }

    private var runningView: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let elapsed = model.speedTestStarted.map { ctx.date.timeIntervalSince($0) } ?? 0
            let phase = elapsed < 6 ? "Measuring ping…" : elapsed < 18 ? "Testing download…" : "Testing upload…"
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(phase).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("\(Int(elapsed))s").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
                ProgressView(value: min(elapsed / 26, 0.97))
                    .tint(Color(red: 0.16, green: 0.47, blue: 1.0))
                Text(model.speedTestRunning == "vpn" ? "Through the VPN tunnel" : "Router's direct internet line")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
    }

    private func resultView(_ r: SpeedResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                metric("arrow.down.circle.fill", value: r.download_mbps, unit: "Mbit/s", label: "Download", tint: .blue)
                Divider().frame(height: 34)
                metric("arrow.up.circle.fill", value: r.upload_mbps, unit: "Mbit/s", label: "Upload", tint: .purple)
                Divider().frame(height: 34)
                metric("timer", value: r.ping_ms, unit: "ms", label: "Ping", tint: .green, decimals: 0,
                       detail: r.jitter_ms.map { "±\(Int($0))" })
            }
            HStack(spacing: 4) {
                if r.cpuLimited {
                    Image(systemName: "cpu").foregroundStyle(.orange)
                    Text("Router CPU maxed out, so your line may be faster.").foregroundStyle(.orange)
                } else {
                    Text(caption(r)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10.5))
            if r.cpuLimited {
                Text(caption(r)).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            if let e = r.error {
                Text("Last attempt failed: \(e)").font(.system(size: 10.5)).foregroundStyle(.orange)
            }
        }
    }

    private func caption(_ r: SpeedResult) -> String {
        var parts = [r.path == "vpn" ? "Through VPN" : "Direct"]
        if let s = r.server, !s.isEmpty { parts.append("Cloudflare \(s)") }
        if let d = r.date { parts.append(d.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }

    private func metric(_ symbol: String, value: Double?, unit: String, label: String, tint: Color,
                        decimals: Int = 1, detail: String? = nil) -> some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value.map { String(format: "%.\(decimals)f", $0) } ?? "–")
                    .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            HStack(spacing: 3) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(label)
                if let detail { Text(detail).foregroundStyle(.tertiary) }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Custom controls (match the rest of the menu)

private let blue = Color(red: 0.16, green: 0.47, blue: 1.0)

private struct Segmented: View {
    @Binding var selection: String
    let options: [(String, String)]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { tag, label in
                Button { withAnimation(.easeInOut(duration: 0.15)) { selection = tag } } label: {
                    Text(label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(selection == tag ? Color.white : Color.secondary)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Capsule().fill(selection == tag ? blue : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

private struct RunButton: View {
    let title: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "play.fill").font(.system(size: 10))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(blue.opacity(hover ? 0.85 : 1)))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
