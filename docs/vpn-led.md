# VPN status LED

`router/vpn-led/install.sh`

The SF1200's single top LED is driven by an I2C LED controller with only **blue** and **white** channels, so it can't show green or other colors. By default the firmware only shows "online" (white) and "no internet" (breathing blue). This adds VPN and Tailscale states.

| Situation | LED |
|---|---|
| No internet | Breathing blue (stock) |
| Internet up, **Tailscale not connected** | Steady **white / blue alternating** (0.5 s each) |
| VPN connected | **Solid blue** |
| VPN switched on but not connected (connecting, failed, dropped) | **Fast blinking blue** (~2×/s) |
| VPN off, internet up | Solid white (stock) |

A Tailscale problem takes priority over the VPN states. The Tailscale pattern only appears if Tailscale is installed.

## Install / uninstall

```bash
ssh glrouter 'sh -s' < router/vpn-led/install.sh
```

The uninstall command is at the top of the script.

## How it works

- **`/etc/vpn-led/patch.sh`** edits GL.iNet's LED code (`/lib/functions/gl_util.sh`). It replaces the SF1200 "online" display with `sft1200_online_led` and the "no internet" display with `sft1200_offline_led`.
  - It works on a copy and swaps it in only if it passes `sh -n`.
  - It saves the stock file to `/etc/gl_util.sh.orig`.
  - It's versioned: an older patch is upgraded cleanly.
  - If a future firmware changes the LED code so the hooks aren't found, it logs that and does nothing, leaving the stock LED behavior.
- **"VPN wanted"** means any `route_policy` rule (WireGuard or OpenVPN) is enabled, which is what the side switch and the dashboard toggle. **"VPN connected"** is `/tmp/wireguard/wgclient*_state` or `/tmp/ovpnclient/*_state` = `connected`.
- **`/etc/vpn-led/ts-health.sh`** checks Tailscale and writes `ok`/`bad` to `/tmp/ts-health`. Tailscale counts as not connected until a check proves otherwise. It checks every 10 s while Tailscale isn't connected and every 60 s while it is, and only while the internet is up.
- **`/etc/vpn-led/ts-blink.sh`** draws the steady white/blue pattern. GL.iNet's LED daemon only redraws every ~2.5 s, which is too slow for a steady rhythm, so while Tailscale is down the daemon steps aside and this script drives the LED.
  - The daemon writes `/tmp/led-online` (uptime = online, `0` = showing "no internet"), so the blinker stops the moment the "no internet" display takes over.
  - A 20 s staleness timeout covers a busy CPU.
- **`/etc/init.d/vpn-led`** reapplies the patch at every boot, before the LED daemon starts, and starts the two helpers. Both are on the firmware-update keep-list.

## LED hardware notes

The controller sits at I2C bus 0, address `0x30`. Register `0x04` selects the mode per channel: `0x01` = blue on, `0x04` = white on, `0x02` = blue blink, `0x08` = white blink, `0x00` = off. Registers `0x01`, `0x02`, and `0x05` set blink period, duty cycle, and fade.

**It's write-only.** Reading it (`i2cget`) can hang the I2C bus, and every LED write then fails until the router is power-cycled. See [troubleshooting](troubleshooting.md).
