# Router helpers and speed test

`router/router-app/install.sh` installs three scripts in `/etc/router-app/` (kept across firmware updates). RouterBar uses them, but they work fine on their own.

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
| `vpn-on`, `vpn-off` | Same as flipping the side switch (`/etc/gl-switch.d/vpn.sh`) |
| `tailscale-restart` | Restarts the Tailscale service |
| `reboot` | Clean reboot after 2 s |
| `speedtest-direct`, `speedtest-vpn` | Runs the speed test and prints its JSON |

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
