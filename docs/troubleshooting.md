# Troubleshooting

## `ssh: no matching host key type found. Their offer: ssh-rsa`

The router's Dropbear only offers RSA. Add `HostKeyAlgorithms +ssh-rsa` and `PubkeyAcceptedAlgorithms +ssh-rsa` to the host in `~/.ssh/config` (see [SSH setup](ssh-setup.md)). For `scp`, also add `-O`.

## The LED stopped changing / `i2c_siflower ... controller timed out` in `logread`

Something tried to **read** from the LED controller (`i2cget -y 0 0x30 …`). It's write-only, and a read can hang the I2C bus. Every later write then times out. Software can't recover it, and rebinding the driver doesn't help: **power-cycle or reboot the router**. Never use `i2cget` on address `0x30`.

## Tailscale: `Segmentation fault` from the `tailscale` command

The router is out of memory. The CLI is a second large Go program next to `tailscaled`. Make sure `zram-swap` is installed and running (`cat /proc/swaps`). The installer and auto-reinstaller both set it up.

## Tailscale takes a minute or more to come back after a restart

That's normal on this CPU. Starting `tailscaled` also triggers network and firewall reloads. The LED shows white/blue until it connects.

## Tailscale missing after a firmware update

If "Keep Settings" was ticked, wait a few minutes after the router gets internet: it reinstalls itself. Check with `ssh glrouter logread -e tailscale-autoinstall`. If "Keep Settings" was off, run `sh router/tailscale/install.sh`.

## Router unreachable after changing the LAN subnet

Your computer still has an address in the old range. Turn Wi-Fi off and on, or reconnect to the router's network, to get a new address. Update `HostName` for `glrouter` in `~/.ssh/config`. Your computer will see the router's SSH key at the new address, but it's the same key. Re-run the Tailscale installer to advertise the new subnet.

## Speed test shows ~90 Mbit/s with "Router CPU maxed out"

The SF1200 can't decrypt HTTPS faster than that. Test from a computer for your line's real maximum. The router test is still useful for checking the upstream link and comparing direct vs. VPN.

## Speed test upload is 0

That came from an old version, which buffered the upload in RAM. Re-run `router/router-app/install.sh`.

## Restarts flagged as PROBLEM

```bash
ssh glrouter cat /etc/reboot-log/history.log
ls /etc/reboot-log/prev-1/     # evidence from the latest problem restart
```

The entry says what triggered the flag (low memory, high load, or log messages). Low memory usually points at Tailscale plus something else using RAM. The memory guard should stop Tailscale first, so check whether it's running: `ps | grep memguard`.
