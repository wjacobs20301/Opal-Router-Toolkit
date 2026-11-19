#!/bin/sh
# GL-SFT1200: show VPN state on the top LED.
#   Tailscale not connected  -> steady white/blue alternating blink (internet up, Tailscale not)
#   VPN connected            -> solid blue
#   VPN on but not connected -> fast blinking blue (connecting, failed or dropped)
#   VPN off, internet up     -> solid white   (stock behaviour)
#   no internet              -> breathing blue (stock behaviour)
#
# Install (from the repo root):
#   ssh glrouter 'sh -s' < router/vpn-led/install.sh
#
# Installs:
#   /etc/vpn-led/patch.sh   applies the LED change if missing (safe to run any time)
#   /etc/vpn-led/ts-health.sh  checks Tailscale every 60s, writes ok/bad to /tmp/ts-health
#   /etc/vpn-led/ts-blink.sh   drives the white/blue blink while Tailscale is down
#   /etc/init.d/vpn-led     runs patch.sh at every boot (before the LED daemon) and starts ts-health
#   /etc/sysupgrade.conf    keeps both across firmware updates ("Keep Settings")
#
# Uninstall:
#   ssh glrouter '/etc/init.d/vpn-led stop; /etc/init.d/vpn-led disable; rm -rf /etc/init.d/vpn-led /etc/vpn-led; \
#     sed -i "/vpn-led/d" /etc/sysupgrade.conf; \
#     cp /etc/gl_util.sh.orig /lib/functions/gl_util.sh; /etc/init.d/gl_led restart'

set -e
mkdir -p /etc/vpn-led

cat > /etc/vpn-led/patch.sh <<'PATCH'
#!/bin/sh
# Re-applies the VPN LED change to gl_util.sh if it is missing.
# Never leaves gl_util.sh half-edited: works on a copy and only swaps it in if it checks out.
F=/lib/functions/gl_util.sh
MARK="# vpn-led-patch v6"

grep -q "$MARK" "$F" && exit 0                 # current version already applied

# An older version is applied: go back to the stock file first, then re-apply.
if grep -q "# vpn-led-patch" "$F"; then
    [ -f /etc/gl_util.sh.orig ] && ! grep -q "# vpn-led-patch" /etc/gl_util.sh.orig \
        || { logger -t vpn-led "no clean backup to upgrade from, skipping"; exit 0; }
    cp /etc/gl_util.sh.orig "$F"
fi

grep -q "^online_led_display()" "$F" || { logger -t vpn-led "LED code changed, skipping"; exit 0; }

TMP=/tmp/gl_util.sh.vpnled
cp "$F" "$TMP"
sed -i '/"sft1200")/{n;s/gl_i2c_led white daemon/sft1200_online_led/}' "$TMP"
grep -q "^ *sft1200_online_led$" "$TMP" || { rm -f "$TMP"; logger -t vpn-led "hook point not found, skipping"; exit 0; }
# Also hook the "no internet" display so it marks the internet as down right away.
# Optional: without it, the blinker falls back to a 20s staleness timeout.
sed -i '/"sft1200")/{n;s/gl_i2c_led blue_breath daemon/sft1200_offline_led/}' "$TMP"
grep -q "^ *sft1200_offline_led$" "$TMP" || logger -t vpn-led "offline hook not found, using timeout only"

cat >> "$TMP" <<'EOF'

# vpn-led-patch v6
#   Tailscale not connected             -> white/blue alternating (driven by /etc/vpn-led/ts-blink.sh)
# /tmp/led-online tells ts-blink.sh / ts-health.sh whether the internet is up:
#   uptime seconds = online (refreshed every LED cycle), 0 = offline display active.
sft1200_led_online_mark() {
    echo "$1" > /tmp/led-online.tmp && mv /tmp/led-online.tmp /tmp/led-online
}

sft1200_offline_led() {
    sft1200_led_online_mark 0
    gl_i2c_led blue_breath daemon
}

#   VPN connected                       -> solid blue
#   VPN turned on but not connected     -> blinking blue (connecting, failed or dropped)
#   VPN off                             -> white
sft1200_vpn_wanted() {
    local i=0
    while [ $i -lt 10 ]; do
        [ "$(uci -q get route_policy.@rule[$i].enabled)" = "1" ] && \
            case "$(uci -q get route_policy.@rule[$i].via_type)" in
                wireguard|openvpn) return 0 ;;
            esac
        i=$((i + 1))
    done
    return 1
}

sft1200_online_led() {
    # Tell the Tailscale blinker the internet is up.
    sft1200_led_online_mark "$(cut -d. -f1 /proc/uptime)"
    # Internet is up but Tailscale is not: /etc/vpn-led/ts-blink.sh drives the LED
    # (white/blue alternating); stay out of its way.
    [ "$(cat /tmp/ts-health 2>/dev/null)" = "bad" ] && return
    for s in /tmp/wireguard/wgclient*_state /tmp/ovpnclient/ovpnclient*_state; do
        [ -f "$s" ] && [ "$(cat "$s")" = "connected" ] && { gl_i2c_led blue daemon; return; }
    done
    if sft1200_vpn_wanted; then
        # Blinking blue, about twice a second. Write-only, no chip reset (avoids flicker).
        set_i2c_led_brightness
        i2cset -f -y 0 0x30 0x01 0x03   # period 0.512s
        i2cset -f -y 0 0x30 0x02 0x7f   # 50% on
        i2cset -f -y 0 0x30 0x05 0x00   # no fade (breathing sets this to 0xFF)
        i2cset -f -y 0 0x30 0x04 0x02   # blue channel, blink mode
    else
        gl_i2c_led white daemon
    fi
}
EOF

sh -n "$TMP" || { rm -f "$TMP"; logger -t vpn-led "syntax check failed, skipping"; exit 0; }

cp "$F" /etc/gl_util.sh.orig                   # backup of this firmware's stock file
cp "$TMP" "$F"
rm -f "$TMP"
logger -t vpn-led "applied"

# If the LED daemon is already running, restart it so it picks up the change.
pgrep -f /usr/bin/gl_led >/dev/null && /etc/init.d/gl_led restart >/dev/null 2>&1
exit 0
PATCH
chmod +x /etc/vpn-led/patch.sh

cat > /etc/vpn-led/ts-health.sh <<'HEALTH'
#!/bin/sh
# Writes /tmp/ts-health for the LED and RouterBar:
#   ok    Tailscale connected
#   bad   Tailscale should be connected but isn't (LED shows white/blue)
#   off   turned off on purpose (RouterBar switch or `tailscale down`); LED stays normal
#
# Light on the router: the Tailscale CLI (a 25 MB program) only runs when the router has
# room for it - CPU load under 8 (normal is 3-6), 25 MB+ usable memory, no VPN switch in progress - at the
# lowest priority with a 45 s limit; otherwise the last state is kept. Every 30 s while
# there's a problem, every 2 minutes while connected. Only while the internet is up.
OUT=/tmp/ts-health
STATE=/root/ts/tailscaled.state
# GNU timeout first: inside BusyBox nice, "timeout" would be BusyBox's, which has other options.
TS="timeout 45 nice -n 19 /root/ts/tailscale --socket=/var/run/tailscale/tailscaled.sock"
echo bad > $OUT
last=0          # uptime of the last full check
was_online=0
set_state() {
    old=$(cat $OUT 2>/dev/null)
    [ "$old" = "$1" ] && return
    echo "$1" > $OUT
    case "$1" in
        ok)  logger -t vpn-led "Tailscale connected" ;;
        bad) logger -t vpn-led "Tailscale not connected, LED alternating white/blue" ;;
        off) logger -t vpn-led "Tailscale turned off" ;;
    esac
}
# Internet up = the LED daemon is showing an online state (see sft1200_led_online_mark).
online() {
    local s; s=$(cat /tmp/led-online 2>/dev/null)
    [ -n "$s" ] && [ "$s" != 0 ] && [ $(($(cut -d. -f1 /proc/uptime) - s)) -le 20 ]
}
# Room to run the CLI without pushing the router over the edge?
roomy() {
    [ "$(cut -d. -f1 /proc/loadavg)" -lt 8 ] || return 1     # normal here: 3-6; crashes at 11+
    [ "$(awk '/MemAvailable/{a=$2} /SwapFree/{s=$2} END{printf "%d", a + s / 2}' /proc/meminfo)" -ge 25000 ] || return 1
    # A GL.iNet VPN switch (side switch / dashboard / RouterBar) is running
    if [ -e /var/lock/gl-switch.lock ] && ! flock -n /var/lock/gl-switch.lock true; then return 1; fi
    pgrep -f "vpn-client|setup_autovpn" >/dev/null && return 1
    return 0
}
while :; do
    sleep 2
    if [ ! -f "$STATE" ]; then echo ok > $OUT; continue; fi
    if [ -e /tmp/ts-user-off ]; then set_state off; continue; fi
    if ! pidof tailscaled >/dev/null; then set_state bad; continue; fi     # free check
    up=$(cut -d. -f1 /proc/uptime)
    if ! online; then was_online=0; continue; fi                         # internet down
    interval=120; [ "$(cat $OUT)" != "ok" ] && interval=30
    if [ $was_online = 0 ] || [ $((up - last)) -ge $interval ]; then
        roomy || continue                                                # busy: try later
        was_online=1; last=$up
        J=$($TS status --json --peers=false 2>/dev/null)
        bs=$(echo "$J" | jsonfilter -e @.BackendState 2>/dev/null)
        if [ "$bs" = "Running" ] && [ "$(echo "$J" | jsonfilter -e @.Self.Online 2>/dev/null)" = "true" ]; then
            set_state ok
        elif [ "$bs" = "Stopped" ]; then
            set_state off
        elif [ -n "$J" ]; then
            set_state bad
        fi                                     # no answer (timed out): keep last state
    fi
done
HEALTH
chmod +x /etc/vpn-led/ts-health.sh

cat > /etc/vpn-led/ts-blink.sh <<'BLINK'
#!/bin/sh
# While Tailscale is down and the internet is up, blink the LED white/blue steadily.
# Internet up = /tmp/led-online holds a recent uptime; the LED daemon sets it to 0 the
# moment it shows "no internet", and the blinker then leaves the LED alone.
# Re-checks before every color, so it starts/stops within half a second.
w() { i2cset -f -y 0 0x30 0x04 "$1"; }   # 0x04 white, 0x01 blue, 0x00 off
active() {
    [ "$(cat /tmp/ts-health 2>/dev/null)" = "bad" ] || return 1
    local s; s=$(cat /tmp/led-online 2>/dev/null)
    [ -n "$s" ] && [ "$s" != 0 ] && [ $(($(cut -d. -f1 /proc/uptime) - s)) -le 20 ]
}
color=0x04
running=0
while :; do
    if active; then
        if [ $running = 0 ]; then
            i2cset -f -y 0 0x30 0x06 0x0a; i2cset -f -y 0 0x30 0x07 0x0a   # brightness
            i2cset -f -y 0 0x30 0x05 0x00                                  # no fade
            running=1; color=0x04
        fi
        w $color; usleep 350000; w 0x00; usleep 150000
        [ $color = 0x04 ] && color=0x01 || color=0x04
    else
        running=0
        usleep 500000
    fi
done
BLINK
chmod +x /etc/vpn-led/ts-blink.sh

cat > /etc/init.d/vpn-led <<'INIT'
#!/bin/sh /etc/rc.common
# Re-apply the VPN LED change at boot, just before gl_led (START=97) starts,
# and start the Tailscale health check that the LED reads.
START=96
STOP=10
start() {
    /etc/vpn-led/patch.sh
    start-stop-daemon -S -b -m -p /var/run/ts-health.pid -a /etc/vpn-led/ts-health.sh
    start-stop-daemon -S -b -m -p /var/run/ts-blink.pid -a /etc/vpn-led/ts-blink.sh
}
stop() {
    start-stop-daemon -K -p /var/run/ts-health.pid >/dev/null 2>&1
    start-stop-daemon -K -p /var/run/ts-blink.pid >/dev/null 2>&1
    rm -f /var/run/ts-health.pid /var/run/ts-blink.pid
}
INIT
chmod +x /etc/init.d/vpn-led
/etc/init.d/vpn-led enable

for p in /etc/vpn-led/ /etc/init.d/vpn-led /etc/rc.d/S96vpn-led; do
    grep -qx "$p" /etc/sysupgrade.conf || echo "$p" >> /etc/sysupgrade.conf
done

/etc/init.d/vpn-led stop
/etc/init.d/vpn-led start
grep -q "# vpn-led-patch v6" /lib/functions/gl_util.sh && echo "VPN LED: installed and active." || echo "VPN LED: installed, but patch not applied (see logread -e vpn-led)."
