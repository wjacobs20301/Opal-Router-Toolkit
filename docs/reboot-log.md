# Reboot log

`router/reboot-log/install.sh`

The router's system log lives in RAM, so after an unexpected restart there's normally no record of why it happened. This keeps a small record on flash.

## Labels

| Label | Meaning | Flagged? |
|---|---|---|
| `CLEAN` | Normal reboot (dashboard, RouterBar, `reboot`) | No |
| `UNPLUGGED` | Power was cut while the router was healthy (unplugged, outage). Normal for a travel router | No |
| `UPDATE` | Firmware version changed | No |
| `PROBLEM` | Power was cut **and** the 5 minutes before showed trouble: usable memory < 15 MB, load ≥ 8, or crash / out-of-memory / "low memory" messages in the log. Most likely a freeze (the hardware watchdog resets the router after ~21 s without a response) or a kernel crash | **Yes** |

From the router's side, an unplug, a watchdog reset, and a kernel panic look the same: the power just stops. The chip doesn't record a reset reason, so the label is an educated guess from the last minutes of data.

## Files (`/etc/reboot-log/`, kept across firmware updates)

| File | |
|---|---|
| `history.log` | One line per boot with label and reason. PROBLEM entries include the evidence |
| `heartbeat` | Latest snapshot (every 30 s): memory, load, Tailscale, VPN, top processes |
| `recent` | Key numbers from the last 10 snapshots (5 minutes) |
| `syslog-latest` | System log copy, every 5 minutes and at clean shutdown |
| `prev-1..3/` | Evidence from the last 3 PROBLEM restarts |

```bash
ssh glrouter cat /etc/reboot-log/history.log
```

## Notes

- About 2 small flash writes per minute, which is well within what the router's NAND storage (with wear leveling) can handle.
- The boot entry's timestamp may lag until the router syncs its clock over NTP.
