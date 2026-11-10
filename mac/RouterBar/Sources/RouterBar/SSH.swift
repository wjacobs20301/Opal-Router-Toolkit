import Foundation

/// Runs commands on the router over SSH, using the Mac's ~/.ssh/config host aliases:
///   glrouter     – router's LAN address (at home, on its Wi-Fi)
///   glrouter-ts  – router's Tailscale address (anywhere)
enum SSH {
    enum Route: String, Sendable {
        case local = "Wi-Fi"
        case tailscale = "Tailscale"
    }

    struct Failure: Error, Sendable { let message: String }

    /// SSH host aliases (from ~/.ssh/config). Change with:
    ///   defaults write local.routerbar localHost my-router
    ///   defaults write local.routerbar tailscaleHost my-router-ts
    static var hosts: [(Route, String)] {
        let d = UserDefaults.standard
        return [(.local, safeHost(d.string(forKey: "localHost")) ?? "glrouter"),
                (.tailscale, safeHost(d.string(forKey: "tailscaleHost")) ?? "glrouter-ts")]
    }

    /// Accepts only plain host names / aliases / addresses (optionally user@), never anything
    /// ssh could read as an option (e.g. "-oProxyCommand=...").
    static func safeHost(_ h: String?) -> String? {
        guard let h, !h.isEmpty, h.count <= 253, !h.hasPrefix("-"),
              h.range(of: #"^[A-Za-z0-9._@:\[\]-]+$"#, options: .regularExpression) != nil else { return nil }
        return h
    }

    /// Runs `command` on the first host that answers. `preferred` is tried first;
    /// `tailscaleOnly` skips the router's Wi-Fi address.
    static func run(_ command: String, preferred: Route? = nil, tailscaleOnly: Bool = false,
                    timeout: TimeInterval = 12) async -> Result<(Route, Data), Failure>
    {
        var order = tailscaleOnly ? hosts.filter { $0.0 == .tailscale } : hosts
        if let p = preferred, let i = order.firstIndex(where: { $0.0 == p }) {
            order.insert(order.remove(at: i), at: 0)
        }
        var lastError = "router unreachable"
        for (route, host) in order {
            switch await runOnce(host: host, command: command, timeout: timeout) {
            case .success(let data): return .success((route, data))
            case .failure(let e): lastError = e.message
            }
        }
        return .failure(Failure(message: lastError))
    }

    private static func runOnce(host: String, command: String, timeout: TimeInterval) async
        -> Result<Data, Failure>
    {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=4",
                           "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1",
                           "--", host, command]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice

            let once = Once(cont)
            let finish: @Sendable (Result<Data, Failure>) -> Void = { once.resume($0) }

            p.terminationHandler = { proc in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus == 0 {
                    finish(.success(data))
                } else {
                    let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    finish(.failure(Failure(message: e.trimmingCharacters(in: .whitespacesAndNewlines))))
                }
            }
            do { try p.run() } catch {
                finish(.failure(Failure(message: error.localizedDescription))); return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { p.terminate() }
                finish(.failure(Failure(message: "timed out")))
            }
        }
    }
}

/// Resumes a continuation exactly once (process exit and timeout can race).
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Result<Data, SSH.Failure>, Never>?
    init(_ c: CheckedContinuation<Result<Data, SSH.Failure>, Never>) { cont = c }
    func resume(_ r: Result<Data, SSH.Failure>) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume(returning: r)
    }
}
