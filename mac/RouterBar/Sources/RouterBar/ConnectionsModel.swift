import Foundation

// MARK: - Data from the router

/// /etc/router-app/wan.sh
struct WanSnapshot: Codable, Sendable {
    struct Interface: Codable, Sendable, Identifiable, Equatable {
        var name: String          // wan, wwan, tethering, ...
        var type: String          // Ethernet, Repeater, Tethering, Cellular
        var up: Bool
        var state: String         // ACTIVE when load balancing uses it
        var device: String
        var ip: String
        var gateway: String
        var weight: Int
        var disabled: Bool
        var rx_bytes: Int64
        var tx_bytes: Int64
        var id: String { name }
    }
    var mode: String              // balance | failover
    var uptime: Int
    var interfaces: [Interface]
}

/// /etc/router-app/latency.sh
struct LatencyResult: Codable, Sendable {
    var path: String?
    var sent: Int?
    var received: Int?
    var loss_pct: Int?
    var min_ms: Double?
    var avg_ms: Double?
    var max_ms: Double?
    var jitter_ms: Double?
    var error: String?
}

// MARK: - Results of tests run from this Mac

struct MacInternetResult: Sendable {
    var downMbps: Double
    var upMbps: Double
    var latencyMs: Double
    var responsivenessRPM: Double?
    var server: String
    var date = Date()
}

struct MacRouterResult: Sendable {
    var latencyMs: Double?
    var lossPct: Int?
    var downMbps: Double?
    var upMbps: Double?
    var via: String
    var error: String?
    var date = Date()
}

/// One speed sample for a connection (Mbit/s).
struct RateSample: Sendable { var down: Double; var up: Double }

// MARK: - Model

@MainActor
final class ConnectionsModel: ObservableObject {
    let router: RouterModel

    @Published private(set) var snapshot: WanSnapshot?
    @Published private(set) var history: [String: [RateSample]] = [:]     // last 60 samples
    @Published private(set) var lastError: String?

    @Published private(set) var latency: [String: LatencyResult] = [:]     // key: test path
    @Published private(set) var speed: [String: SpeedResult] = [:]
    @Published private(set) var runningTest: String?                      // e.g. "speed:wan:wwan"

    @Published private(set) var macInternet: MacInternetResult?
    @Published private(set) var macInternetError: String?
    @Published private(set) var macRouter: MacRouterResult?
    @Published private(set) var macTest: String?                          // "internet" | "router"

    private var timer: Timer?
    private var previous: (date: Date, counters: [String: (Int64, Int64)])?

    init(router: RouterModel) { self.router = router }

    /// Made-up data for screenshots (`--demo`): three connections load balancing, with history.
    func loadDemo() {
        snapshot = WanSnapshot(mode: "balance", uptime: 12345, interfaces: [
            .init(name: "wan", type: "Ethernet", up: true, state: "ACTIVE", device: "eth0.2", ip: "192.0.2.25",
                  gateway: "192.0.2.1", weight: 2, disabled: false, rx_bytes: 0, tx_bytes: 0),
            .init(name: "wwan", type: "Repeater", up: true, state: "ACTIVE", device: "sta0", ip: "198.51.100.40",
                  gateway: "198.51.100.1", weight: 1, disabled: false, rx_bytes: 0, tx_bytes: 0),
            .init(name: "tethering", type: "Tethering", up: true, state: "ACTIVE", device: "eth1", ip: "172.20.10.2",
                  gateway: "172.20.10.1", weight: 1, disabled: false, rx_bytes: 0, tx_bytes: 0),
        ])
        for (name, base) in [("wan", 38.0), ("wwan", 14.0), ("tethering", 9.0)] {
            history[name] = (0..<60).map { i in
                let x = Double(i)
                return RateSample(down: max(0, base * (0.55 + 0.45 * sin(x / 6.0 + base)) + Double((i * 7) % 5)),
                                  up: max(0, base * 0.25 * (0.6 + 0.4 * cos(x / 5.0 + base))))
            }
        }
        latency["wan:wan"] = LatencyResult(path: "wan:wan", sent: 8, received: 8, loss_pct: 0, min_ms: 9.1, avg_ms: 10.4, max_ms: 12.0, jitter_ms: 0.9)
        speed["wan:wan"] = SpeedResult(path: "wan:wan", server: "YVR", ping_ms: 11, jitter_ms: 1, download_mbps: 87.2, upload_mbps: 41.5,
                                       cpu_download: 93, cpu_upload: 70, error: nil, date: Date())
        latency["wan:tethering"] = LatencyResult(path: "wan:tethering", sent: 8, received: 8, loss_pct: 0, min_ms: 31.0, avg_ms: 38.6, max_ms: 52.3, jitter_ms: 6.2)
        macInternet = MacInternetResult(downMbps: 241.3, upMbps: 48.7, latencyMs: 18, responsivenessRPM: nil, server: "aaplimg.com")
        macRouter = MacRouterResult(latencyMs: 3.4, lossPct: 0, downMbps: 31.2, upMbps: 14.6, via: "Wi-Fi / Ethernet")
    }

    // MARK: Live polling (only while the window is open)

    func startPolling() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stopPolling() {
        timer?.invalidate(); timer = nil
        previous = nil
    }

    private var polling = false
    private func poll() {
        guard !polling else { return }
        polling = true
        Task {
            defer { polling = false }
            let r = await SSH.run("/etc/router-app/wan.sh", preferred: router.route,
                                  tailscaleOnly: router.tailscaleOnly, timeout: 8)
            switch r {
            case .success(let (_, data)):
                guard let snap = try? JSONDecoder().decode(WanSnapshot.self, from: data) else {
                    lastError = "Unexpected reply from router (update the router helpers?)"; return
                }
                record(snap)
                snapshot = snap
                lastError = nil
            case .failure(let f):
                lastError = f.message.isEmpty ? "Router unreachable" : f.message
            }
        }
    }

    private func record(_ snap: WanSnapshot) {
        let now = Date()
        var counters: [String: (Int64, Int64)] = [:]
        for i in snap.interfaces { counters[i.name] = (i.rx_bytes, i.tx_bytes) }
        if let prev = previous {
            let dt = now.timeIntervalSince(prev.date)
            if dt > 0.5 {
                for i in snap.interfaces {
                    var sample = RateSample(down: 0, up: 0)
                    if let (rx0, tx0) = prev.counters[i.name], i.up, i.rx_bytes >= rx0, i.tx_bytes >= tx0 {
                        sample = RateSample(down: Double(i.rx_bytes - rx0) * 8 / dt / 1e6,
                                            up: Double(i.tx_bytes - tx0) * 8 / dt / 1e6)
                    }
                    history[i.name, default: []].append(sample)
                    if history[i.name]!.count > 60 { history[i.name]!.removeFirst() }
                }
            }
        }
        previous = (now, counters)
    }

    /// Share of traffic load balancing gives this connection (by weight, among connected ones).
    func share(of i: WanSnapshot.Interface) -> Double? {
        guard let s = snapshot, i.up, !i.disabled else { return nil }
        let total = s.interfaces.filter { $0.up && !$0.disabled }.reduce(0) { $0 + max($1.weight, 0) }
        return total > 0 ? Double(max(i.weight, 0)) / Double(total) : nil
    }

    // MARK: Tests on the router

    /// path: "direct", "vpn" or "wan:<name>"
    func runLatency(_ path: String) {
        guard runningTest == nil, let action = Self.action("latency", path) else { return }
        runningTest = "latency:\(path)"
        Task {
            let r = await SSH.run("/etc/router-app/action.sh \(action)", preferred: router.route,
                                  tailscaleOnly: router.tailscaleOnly, timeout: 40)
            switch r {
            case .success(let (_, data)):
                latency[path] = (try? JSONDecoder().decode(LatencyResult.self, from: data))
                    ?? LatencyResult(error: "Unexpected reply from router")
            case .failure(let f):
                latency[path] = LatencyResult(error: f.message.isEmpty ? "Router unreachable" : f.message)
            }
            runningTest = nil
        }
    }

    func runSpeed(_ path: String) {
        guard runningTest == nil, let action = Self.action("speedtest", path) else { return }
        runningTest = "speed:\(path)"
        Task {
            let r = await SSH.run("/etc/router-app/action.sh \(action)", preferred: router.route,
                                  tailscaleOnly: router.tailscaleOnly, timeout: 90)
            var result: SpeedResult
            switch r {
            case .success(let (_, data)):
                result = (try? JSONDecoder().decode(SpeedResult.self, from: data))
                    ?? SpeedResult(error: "Unexpected reply from router")
            case .failure(let f):
                result = SpeedResult(error: f.message.isEmpty ? "Router unreachable" : f.message)
            }
            result.date = Date()
            speed[path] = result
            runningTest = nil
        }
    }

    /// Builds an allowed router action name; nil for anything unexpected.
    private static func action(_ kind: String, _ path: String) -> String? {
        switch path {
        case "direct", "vpn": return "\(kind)-\(path)"
        default:
            guard path.hasPrefix("wan:") else { return nil }
            let name = String(path.dropFirst(4))
            guard !name.isEmpty, name.range(of: "^[a-z0-9_]+$", options: .regularExpression) != nil else { return nil }
            return "\(kind)-wan-\(name)"
        }
    }

    // MARK: Tests from this Mac

    /// Mac -> internet, with Apple's built-in networkQuality tool.
    func runMacInternet() {
        guard macTest == nil else { return }
        macTest = "internet"
        macInternetError = nil
        Task {
            let r = await Proc.run("/usr/bin/networkQuality", ["-c", "-s"], timeout: 90)
            if r.status == 0, let d = try? JSONSerialization.jsonObject(with: r.output) as? [String: Any],
               let dl = d["dl_throughput"] as? Double, let ul = d["ul_throughput"] as? Double {
                macInternet = MacInternetResult(
                    downMbps: dl / 1e6, upMbps: ul / 1e6,
                    latencyMs: d["base_rtt"] as? Double ?? 0,
                    responsivenessRPM: (d["dl_responsiveness"] as? Double) ?? (d["responsiveness"] as? Double),
                    server: (d["test_endpoint"] as? String).map { $0.components(separatedBy: ".").dropFirst().joined(separator: ".") } ?? "Apple")
            } else {
                macInternetError = "networkQuality failed (are you online?)"
            }
            macTest = nil
        }
    }

    /// Mac -> router: ping plus a download and upload against the router's test page.
    func runMacRouter() {
        guard macTest == nil else { return }
        let ip = router.validatedLanIP
        macTest = "router"
        let via = router.route == .tailscale ? "Tailscale" : "Wi-Fi / Ethernet"
        Task {
            var res = MacRouterResult(via: via)
            // Latency
            let p = await Proc.run("/sbin/ping", ["-c", "8", "-i", "0.25", "-q", ip], timeout: 20)
            let out = String(decoding: p.output, as: UTF8.self)
            if let m = out.range(of: #"= [0-9.]+/([0-9.]+)/"#, options: .regularExpression) {
                res.latencyMs = Double(out[m].split(separator: "/")[1])
            }
            if let m = out.range(of: #"([0-9.]+)% packet loss"#, options: .regularExpression) {
                res.lossPct = Int(Double(out[m].split(separator: "%")[0]) ?? 0)
            }
            // Throughput (router's test page caps at 50 MB)
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 60
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: cfg)
            if let url = URL(string: "http://\(ip)/cgi-bin/routerbar-speed?bytes=25000000") {
                let t0 = Date()
                if let (data, resp) = try? await session.data(from: url),
                   (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 1_000_000 {
                    res.downMbps = Double(data.count) * 8 / Date().timeIntervalSince(t0) / 1e6
                } else { res.error = "Couldn't reach the router's test page (update the router helpers?)" }
            }
            if res.error == nil, let url = URL(string: "http://\(ip)/cgi-bin/routerbar-speed") {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                let body = Data(count: 15_000_000)
                let t0 = Date()
                if let (_, resp) = try? await session.upload(for: req, from: body),
                   (resp as? HTTPURLResponse)?.statusCode == 200 {
                    res.upMbps = Double(body.count) * 8 / Date().timeIntervalSince(t0) / 1e6
                }
            }
            session.invalidateAndCancel()
            if res.latencyMs == nil && res.downMbps == nil && res.error == nil { res.error = "Router unreachable" }
            macRouter = res
            macTest = nil
        }
    }
}

// MARK: - Running local tools

enum Proc {
    struct Result: Sendable { var status: Int32; var output: Data }

    static func run(_ path: String, _ args: [String], timeout: TimeInterval) async -> Result {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            let box = ResultBox(cont)
            // Read continuously so large outputs can't fill the pipe and stall the tool.
            DispatchQueue.global().async {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                box.resume(Result(status: p.terminationStatus, output: data))
            }
            do { try p.run() } catch { box.resume(Result(status: -1, output: Data())); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { p.terminate() }
            }
        }
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<Result, Never>?
        init(_ c: CheckedContinuation<Result, Never>) { cont = c }
        func resume(_ r: Result) {
            lock.lock(); let c = cont; cont = nil; lock.unlock()
            c?.resume(returning: r)
        }
    }
}
