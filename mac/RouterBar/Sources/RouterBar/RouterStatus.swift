import Foundation

/// JSON printed by /etc/router-app/status.sh on the router.
struct RouterStatus: Codable, Equatable, Sendable {
    struct Upstream: Codable, Equatable, Sendable {
        var type: String
        var device: String
        var ssid: String
        var signal_dbm: String
        var gateway: String
    }
    struct VPN: Codable, Equatable, Sendable {
        var wanted: Bool
        var state: String          // off | connecting | connected
        var server: String
        var location: String
    }
    struct Tailscale: Codable, Equatable, Sendable {
        var installed: Bool
        var running: Bool
        var health: String         // ok | bad | ""
        var ip: String
    }
    struct Reboots: Codable, Equatable, Sendable {
        var last: String
        var unexpected: Int
    }
    struct Device: Codable, Equatable, Sendable, Identifiable {
        var mac: String
        var ip: String
        var name: String
        var online: Bool
        var lease_expires: Int
        var id: String { mac }
        var displayName: String { name.isEmpty ? "Unknown device" : name }
    }

    var uptime: Int
    var load: String
    var mem_total_kb: Int
    var mem_avail_kb: Int
    var swap_total_kb: Int
    var swap_free_kb: Int
    var disk_free_kb: Int
    var lan_ip: String
    var internet: Bool
    var upstream: Upstream
    var vpn: VPN
    var tailscale: Tailscale
    var reboots: Reboots
    var devices: [Device]
}

/// What the router's LED is showing, derived the same way the router decides it.
enum LEDState: Equatable {
    case noInternet
    case tailscaleDown
    case vpnConnected
    case vpnConnecting
    case online

    init(_ s: RouterStatus) {
        if !s.internet { self = .noInternet }
        else if s.tailscale.installed && s.tailscale.health == "bad" { self = .tailscaleDown }
        else if s.vpn.state == "connected" { self = .vpnConnected }
        else if s.vpn.wanted { self = .vpnConnecting }
        else { self = .online }
    }

    var title: String {
        switch self {
        case .noInternet: return "No internet"
        case .tailscaleDown: return "Tailscale not connected"
        case .vpnConnected: return "Protected by VPN"
        case .vpnConnecting: return "VPN on, not connected"
        case .online: return "Online, VPN off"
        }
    }

    var ledDescription: String {
        switch self {
        case .noInternet: return "LED: breathing blue"
        case .tailscaleDown: return "LED: white/blue alternating"
        case .vpnConnected: return "LED: solid blue"
        case .vpnConnecting: return "LED: fast blinking blue"
        case .online: return "LED: solid white"
        }
    }

    var symbol: String {
        switch self {
        case .noInternet: return "wifi.exclamationmark"
        case .tailscaleDown: return "exclamationmark.triangle"
        case .vpnConnected: return "lock.shield.fill"
        case .vpnConnecting: return "shield.lefthalf.filled"
        case .online: return "wifi.router"
        }
    }
}

/// Result printed by /etc/router-app/speedtest.sh.
struct SpeedResult: Codable, Equatable, Sendable {
    var path: String?           // direct | vpn
    var server: String?         // Cloudflare location code, e.g. YVR
    var ping_ms: Double?
    var jitter_ms: Double?
    var download_mbps: Double?
    var upload_mbps: Double?
    var cpu_download: Int?
    var cpu_upload: Int?
    var error: String?
    var date: Date?             // set by the app

    /// The router's CPU was the bottleneck, so the line may be faster than measured.
    var cpuLimited: Bool { (cpu_download ?? 0) >= 90 }
}
