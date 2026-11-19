# Changelog

## 1.1.0

**Fixed: turning the VPN on from RouterBar could freeze the router** (watchdog reset). A VPN switch makes GL.iNet restart its whole VPN system. During that restart, the Tailscale health check kept launching the 25 MB Tailscale CLI, and RouterBar opened a new SSH connection every 15 s, so CPU load reached 19 and the router stopped responding. Now:
- The health check skips the CLI during VPN switches or when the router is busy (load ≥ 8, < 25 MB free), and runs it at the lowest priority with a time limit. It also fixed a BusyBox quirk where `nice … timeout` used the wrong `timeout`.
- VPN on/off does nothing if already in that state, and never stacks switches.
- RouterBar reuses one SSH connection and shows "Switching…" while the VPN changes.
- Measured: VPN on now peaks around 9–10 load and recovers, instead of 19 and a freeze.

**New: Tailscale on/off.** Toggle it from RouterBar, with a warning if you're connected through Tailscale. It's off until turned on or the next boot, since the router always reconnects at startup. Turning it off on purpose doesn't trigger the LED warning.

**New: Connections window** in RouterBar:
- Each load-balanced connection (Ethernet, Repeater, Tethering, Cellular) with live traffic, a 2-minute graph, its load-balance share, and latency/speed tests through that connection alone.
- Router tests through the normal route or the VPN.
- Mac → Internet (Apple `networkQuality`) and Mac → Router tests.

New router helpers: `wan.sh`, `latency.sh`, `via.sh`, and the `routerbar-speed` test page.

## 1.0.0

First release for the GL.iNet GL-SFT1200 (Opal).

**Router add-ons**
- **VPN status LED:** solid blue = VPN connected, fast blinking blue = switched on but not connected, white = VPN off, steady white/blue = Tailscale not connected.
- **Tailscale** for the 128 MB router: compressed memory, a memory guard, LAN sharing in both directions, and automatic reinstall after firmware updates (a pinned version, fingerprint-checked, with time and size limits).
- **Reboot log:** labels restarts as clean, unplugged, firmware update, or a real problem. Unplugging is never flagged.
- **Router helpers:** status JSON, a fixed list of allowed actions, and a Cloudflare speed test, direct or through the VPN.
- **`router/install-all.sh`** and **`router/uninstall-all.sh`** (with `--dry-run`; removes only what the toolkit added).

**RouterBar** (macOS 14+, Apple Silicon and Intel)
- A menu bar icon and an animated 3D model of the router that mirror the real LED.
- VPN and Tailscale controls, connected devices, speed test, router health, and notifications tuned for a travel router.
- Connects over Wi-Fi at home and over Tailscale anywhere.

**Security** (reviewed before release; see [SECURITY.md](SECURITY.md))
- Untrusted Wi-Fi and device names are sanitized on the router.
- SSH host settings are validated, actions and speed test paths are allow-listed, and the dashboard opens only a valid IPv4 address.
- SSH host-key verification protects against impostor routers.
- The app is signed with the hardened runtime.
