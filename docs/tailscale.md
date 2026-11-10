# Tailscale on the SF1200

`router/tailscale/`

GL.iNet's firmware offers Tailscale on some models, but not the SF1200, because it only has 128 MB of RAM. This installs the official Tailscale release with enough safeguards to run reliably.

## What you get

- **Remote access:** reach the router (SSH, web dashboard) and **every device on its LAN** from anywhere on your tailnet. The router advertises its LAN subnet as a route.
- **LAN → tailnet:** devices on the router's Wi-Fi *without* Tailscale can reach your tailnet devices by their `100.x` address. The traffic is address-translated to the router.
- Works with the router's own VPN (NordVPN etc.) on or off: Tailscale's routing rule takes priority, and normal internet traffic still goes through the VPN.

## Install

```bash
sh router/tailscale/install.sh                  # uses the "glrouter" SSH alias
ROUTER=root@192.168.8.1 sh router/tailscale/install.sh
```

The router downloads Tailscale itself, checks it against pinned SHA-256 fingerprints, and starts it. On first install it prints a **sign-in link**. After signing in, **approve the subnet route** for the router in the [Tailscale admin console](https://login.tailscale.com/admin/machines) (⋯ → Edit route settings).

Re-running is safe. `REINSTALL=1` re-downloads the program files.

## Pieces

| File on router | Purpose |
|---|---|
| `/root/ts/tailscale`, `tailscaled` | Official Tailscale release for `mipsle` (not kept across firmware updates, too big) |
| `/root/ts/tailscaled.state` | Your login. Kept across firmware updates |
| `/etc/init.d/tailscale` | procd service: starts at boot, respawns. If the program files are missing, it starts `autoinstall.sh` |
| `/root/ts/autoinstall.sh` | Waits for internet, reinstalls zram, downloads the pinned release and checks fingerprints (3 tries, then waits for next boot) |
| `/root/ts/memguard.sh` | Stops `tailscaled` if usable memory (free + half of free zram) drops below 10 MB. After 5 stops in an hour, Tailscale stays off |
| `zram-swap` package | ~57 MB of compressed swap. Without it, the `tailscale` CLI can't even start next to `tailscaled` |
| `network.tailscale`, `firewall.tailscale` | Interface + firewall zone, with forwarding in both directions to the LAN |

## Measured on an SF1200

| | |
|---|---|
| `tailscaled` memory | ~18–25 MB |
| Usable memory with zram, under load | never below ~39 MB |
| Throughput through Tailscale | ~10–15 Mbit/s (CPU-bound, CPU at 100%) |
| Idle CPU impact | none noticeable |
| Start-up time after boot | ~1 minute or more |

That's fine for SSH, dashboards, printing, and remote desktop, but not for large transfers or using the router as an exit node.

## Updating the pinned Tailscale version

`autoinstall.sh` pins one release, so a firmware update never pulls an untested version:

1. Pick a version from https://pkgs.tailscale.com/stable/ and download `tailscale_<ver>_mipsle.tgz`.
2. Verify it against Tailscale's published `.sha256`, extract it, and run `shasum -a 256` on `tailscale` and `tailscaled`.
3. Update `VER`, `SHA_TAILSCALE`, and `SHA_TAILSCALED` in `router/tailscale/autoinstall.sh`.
4. Run `REINSTALL=1 sh router/tailscale/install.sh`.

## LAN subnet clashes

Every GL.iNet router defaults to `192.168.8.0/24`. If your laptop is on another network with the same range, it reaches that network instead of your router's LAN. Pick an uncommon subnet in the GL.iNet dashboard (Network → LAN), then re-run the installer to advertise the new route, and approve it in the admin console.
