# Contributing

Thanks for your interest! Issues and pull requests are welcome.

## Reporting a problem

Open an issue using the **Bug report** template and include:

- Router model and firmware version: `ssh glrouter 'cat /etc/glversion'`
- Which component (VPN LED, Tailscale, reboot log, router helpers, RouterBar)
- What you expected and what happened
- Relevant logs, for example:

  ```bash
  ssh glrouter 'logread | grep -E "vpn-led|tailscale|reboot-log|router-app" | tail -50'
  ```

**Remove personal details from logs before posting:** public IP addresses, Wi-Fi names, MAC addresses, Tailscale addresses and hostnames.

For security issues, see [SECURITY.md](SECURITY.md) instead.

## Making changes

### Router scripts (`router/`)

- The router runs **BusyBox `ash`** (not bash) on OpenWrt 18.06. Avoid bashisms, and test BusyBox quirks on a real router. For example, BusyBox `tr` has no `[:print:]` classes, and `awk` reads `x (y)` as a function call.
- Keep installers **safe to re-run**, and give each one an uninstall command in its header.
- **Never read the LED controller** (`i2cget` on I2C address `0x30`). It hangs the bus until a reboot.
- Memory is tight (about 30 MB free with Tailscale). Stream data rather than buffering it.
- Before submitting:

  ```bash
  shellcheck -s sh -S warning router/*.sh router/*/*.sh
  ```

### RouterBar (`mac/RouterBar/`)

- Build with `sh mac/RouterBar/build.sh --no-install`. The build should have no warnings.
- Check UI changes with snapshots, which need no real router:

  ```bash
  mac/RouterBar/build/RouterBar.app/Contents/MacOS/RouterBar --demo --snapshot /tmp/shots
  ```

- Keep screenshots in `docs/images/` on **demo data only**.

### Pull requests

- Keep each pull request to one focused change, and describe what you tested and on which firmware.
- Update the matching page in `docs/` if behavior changes.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
