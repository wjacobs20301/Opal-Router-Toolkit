# Security

## What these scripts do on your router

Everything under `router/` runs **as root** on the router, because that's how OpenWrt and GL.iNet firmware work. Before installing, you should know:

- **System file change:** the VPN LED patch edits `/lib/functions/gl_util.sh`, part of GL.iNet's firmware. The original is saved to `/etc/gl_util.sh.orig`, and `router/uninstall-all.sh` restores it.
- **Firewall:** the Tailscale installer adds a `tailscale` firewall zone that allows
  - your tailnet → the router and its LAN (so you can reach it remotely), and
  - the router's LAN → your tailnet (address-translated to the router).

  Anyone on your tailnet who's allowed by your [Tailscale access controls](https://tailscale.com/kb/1018/acls) can reach the router's LAN. Use ACLs if your tailnet is shared.
  Only the main LAN is connected to Tailscale. The **guest Wi-Fi network stays isolated**: it can only reach the internet (and the router's VPN), never your tailnet or the main LAN.
- **Downloads:** the router downloads Tailscale itself from `pkgs.tailscale.com` over verified HTTPS, with a 15-minute and 60 MB limit. It refuses to install anything unless both files are plain files of a sane size that match the SHA-256 fingerprints pinned in `router/tailscale/autoinstall.sh`. The zram packages come from GL.iNet's package feed.
- **Router identity:** RouterBar runs `ssh` in batch mode with normal host-key checking, so it never connects to a device presenting a different key, such as an impostor on a hotel network. It never auto-accepts a new key either.
- **Tailscale key in backups:** the router's Tailscale login (`/root/ts/tailscaled.state`, readable by root only) is on the firmware-update keep-list, so it's also included in GL.iNet's **"Backup settings"** download. GL.iNet's backups already contain your VPN (WireGuard/OpenVPN) keys the same way. Treat backup files as secrets. If one leaks, remove the router from your Tailscale admin console and sign it in again.
- **Logs on flash:** the reboot log keeps recent system log copies in `/etc/reboot-log/` (root-only), so they survive restarts. They contain device names and addresses, not passwords or keys.
- **RouterBar's signing:** it's signed ad hoc (not by a paid Apple Developer ID) with the **hardened runtime** on, which blocks code injection into the running app. It has no third-party dependencies.
- **RouterBar's access:** it connects over SSH as root, using your key. It can only *change* things through `/etc/router-app/action.sh`, which accepts a fixed list of actions (VPN on/off, restart Tailscale, reboot, speed test). Anyone with your SSH key already has full root access, so protect `~/.ssh/glrouter_rsa`.
- **Outbound traffic:** the speed test sends traffic only to `speed.cloudflare.com`.
- **Never stored:** no passwords, VPN keys or tokens are stored by these scripts or the app. Tailscale keeps its own login state in `/root/ts/tailscaled.state` on the router.
- **Untrusted text:** Wi-Fi network names and device names come from other people's equipment. `status.sh` strips them to printable ASCII with no quotes, backslashes or line breaks before they reach RouterBar, and RouterBar only displays them. They're never run as commands.

## Recommended hardening

- **Turn off SSH password logins** once your key works (see [docs/ssh-setup.md](docs/ssh-setup.md)). Your Tailscale devices can reach the router's SSH, so with passwords enabled any device on your tailnet could try to guess the root password.
- Keep the router's admin password strong. It still protects the web dashboard.
- On a shared tailnet, restrict who can reach the router's subnet with Tailscale ACLs.

## Reporting a vulnerability

Please **don't open a public issue** for security problems. Use GitHub's private reporting instead: **Security → Report a vulnerability** on this repository. Include what you found, how to reproduce it, and the firmware version. You'll get a reply as soon as possible. This is a personal project, so there's no formal response time.
