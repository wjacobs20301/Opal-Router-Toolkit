# Router helpers and speed test

`router/router-app/install.sh` installs these scripts in `/etc/router-app/`, plus a small test page, all kept across firmware updates. RouterBar uses them, but they work fine on their own.

## `status.sh`: router status as JSON

It reads only files and `ubus`, with no heavy tools, and runs in under a second:

```bash
ssh glrouter /etc/router-app/status.sh
```

```json
{
  "uptime": 12300, "load": "0.84",
  "mem_total_kb": 118700, "mem_avail_kb": 31800, "swap_total_kb": 58364, "swap_free_kb": 39100,
  "disk_free_kb": 35800, "lan_ip": "192.168.8.1", "internet": true,
  "upstream": { "type": "Wi-Fi", "device": "sta0", "ssid": "Hotel Guest", "signal_dbm": "-61", "gateway": "192.0.2.1" },
  "vpn": { "wanted": true, "state": "connected", "server": "…", "location": "Canada,Vancouver" },
  "tailscale": { "installed": true, "running": true, "health": "ok", "ip": "100.64.0.12" },
  "reboots": { "last": "boot #12: UNPLUGGED - …", "unexpected": 0 },
  "devices": [ { "mac": "…", "ip": "192.168.8.120", "name": "MacBook-Pro", "online": true, "lease_expires": 0 } ]
}
```

`upstream.type` is `Ethernet`, `Wi-Fi` (repeater), `USB tethering`, or `Cellular`. A device is `online` when the router has a live ARP entry for it. `reboots.unexpected` counts only PROBLEM restarts.

## `action.sh`: the only things the app can change

| Action | Effect |
|---|---|
| `vpn-on`, `vpn-off` | Same as flipping the side switch (`/etc/gl-switch.d/vpn.sh`). Does nothing if already in that state, and refuses while another VPN switch is running. GL.iNet's VPN restart is heavy on this router, so switches are never stacked |
| `tailscale-restart` | Restarts the Tailscale service |
| `reboot` | Clean reboot after 2 s |
| `tailscale-on`, `tailscale-off` | Connects/disconnects Tailscale (stays installed). "Off" lasts until turned on or the next boot |
| `speedtest-direct`, `speedtest-vpn`, `speedtest-wan-<name>` | Runs the speed test and prints its JSON |
| `latency-direct`, `latency-vpn`, `latency-wan-<name>` | Runs the latency test and prints its JSON |

Anything else is rejected.

## `speedtest.sh`: internet speed from the router

```bash
ssh glrouter /etc/router-app/speedtest.sh direct   # the router's internet line
ssh glrouter /etc/router-app/speedtest.sh vpn      # through the VPN tunnel (wgclient1)
```

It takes about 25 s and tests against Cloudflare's speed servers (`speed.cloudflare.com`):

- **Ping and jitter:** 6 TCP connect times.
- **Download:** 4 parallel 25 MB transfers. Cloudflare rejects single requests of 100 MB or more.
- **Upload:** 2 parallel 12 MB streams. They're streamed with `curl -T -` so nothing is buffered in the router's small RAM.
- It records CPU use for each phase. **The SF1200 maxes out its CPU decrypting HTTPS at roughly 90 Mbit/s**, so if `cpu_download` ≥ 90 your line may be faster than measured.

```json
{"path":"direct","server":"YVR","ping_ms":21,"jitter_ms":3,"download_mbps":84.6,"upload_mbps":38.9,"cpu_download":71,"cpu_upload":64}
```

Only one test runs at a time. A second one gets `{"error":"A speed test is already running"}`.

## `wan.sh`: load-balanced connections

```bash
ssh glrouter /etc/router-app/wan.sh
```

Lists every connection in GL.iNet's multi-WAN setup (`kmwan`): `wan` (Ethernet), `wwan` (Repeater), `tethering`, `secondwan`, cellular modems. Each entry has whether it's up, the load-balancing state (`ACTIVE` when in use), device, address, gateway, weight, and raw byte counters. It reads only files and `ubus`, so RouterBar polls it every 2 seconds while its Connections window is open, and works out live speeds from the counters.

## `latency.sh` and per-connection tests

```bash
ssh glrouter /etc/router-app/latency.sh direct        # normal route
ssh glrouter /etc/router-app/latency.sh vpn           # through the VPN
ssh glrouter /etc/router-app/latency.sh wan:wwan      # through one specific connection
ssh glrouter /etc/router-app/speedtest.sh wan:wan     # speed test through Ethernet only
```

`latency.sh` sends 8 pings to `1.1.1.1` and reports average, min/max, jitter and loss.

To test **one** connection while load balancing is on, `via.sh` adds a temporary source-based route: an `ip rule` with priority 2 pointing at table 990, with a default route through that connection's gateway. It then binds the test to that connection's address and removes the rule and table afterward, even if the test fails.

## Mac ↔ router test page

`/www/cgi-bin/routerbar-speed` lets RouterBar measure the link between a Mac and the router:

- `GET ?bytes=N` streams N zero bytes.
- `POST` discards the body.

Both are capped at 50 MB. It's served by GL.iNet's web server on the router's LAN, and over Tailscale. Throughput is limited by the router's CPU running the page (roughly 15–40 Mbit/s on the SF1200).
