# Changelog

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
