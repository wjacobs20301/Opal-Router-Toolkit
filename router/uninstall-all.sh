#!/bin/sh
# Removes everything this toolkit installed on the router and restores stock behavior.
#
#   sh router/uninstall-all.sh --dry-run    show what would be removed, change nothing
#   sh router/uninstall-all.sh              asks for confirmation, then removes
#   sh router/uninstall-all.sh --yes        no prompt
#   ROUTER=root@192.168.8.1 sh router/uninstall-all.sh
#
# Afterwards, remove the router from https://login.tailscale.com/admin/machines if you used Tailscale.
set -e
R=${ROUTER:-glrouter}
SSH="ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa"
DRY=""; YES=""
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --yes|-y) YES=1 ;;
        *) echo "unknown option: $a"; exit 1 ;;
    esac
done

if [ -z "$DRY" ] && [ -z "$YES" ]; then
    printf 'Remove the VPN LED, Tailscale, reboot log and router helpers from %s? [y/N] ' "$R"
    read -r answer
    case "$answer" in y|Y|yes) ;; *) echo "Cancelled."; exit 0 ;; esac
fi

$SSH "$R" "DRY='$DRY' sh -s" <<'EOF'
run() { if [ -n "$DRY" ]; then echo "  would run: $*"; else eval "$*"; fi; }
has() { [ -e "$1" ]; }
found=0

echo "== Tailscale"
if has /etc/init.d/tailscale || has /root/ts; then
    found=1
    run "/etc/init.d/tailscale stop 2>/dev/null; /etc/init.d/tailscale disable 2>/dev/null; true"
    run "rm -rf /root/ts /etc/init.d/tailscale /var/run/tailscale"
fi
if uci -q get network.tailscale >/dev/null || uci -q get firewall.tailscale >/dev/null; then
    found=1
    run "uci -q delete network.tailscale; uci commit network"
    run "uci -q delete firewall.tailscale; uci -q delete firewall.tailscale_to_lan; uci -q delete firewall.lan_to_tailscale; uci commit firewall"
fi
if opkg list-installed | grep -q '^zram-swap '; then
    found=1
    run "/etc/init.d/zram stop >/dev/null 2>&1; opkg remove zram-swap kmod-zram >/dev/null; true"
fi

echo "== VPN status LED"
if has /etc/init.d/vpn-led || has /etc/vpn-led; then
    found=1
    run "/etc/init.d/vpn-led stop 2>/dev/null; /etc/init.d/vpn-led disable 2>/dev/null; true"
    run "rm -rf /etc/vpn-led /etc/init.d/vpn-led /tmp/ts-health /tmp/led-online /var/run/ts-health.pid /var/run/ts-blink.pid"
fi
if grep -q '# vpn-led-patch' /lib/functions/gl_util.sh 2>/dev/null; then
    found=1
    if [ -f /etc/gl_util.sh.orig ] && ! grep -q '# vpn-led-patch' /etc/gl_util.sh.orig; then
        run "cp /etc/gl_util.sh.orig /lib/functions/gl_util.sh && rm -f /etc/gl_util.sh.orig"
        run "/etc/init.d/gl_led restart >/dev/null 2>&1; true"
    else
        echo "  WARNING: no clean backup of gl_util.sh found; LED code left as is"
    fi
fi

echo "== Reboot log"
if has /etc/init.d/reboot-log || has /etc/reboot-log; then
    found=1
    run "/etc/init.d/reboot-log stop 2>/dev/null; /etc/init.d/reboot-log disable 2>/dev/null; true"
    run "rm -rf /etc/reboot-log /etc/init.d/reboot-log /var/run/reboot-log.pid"
fi

echo "== Router helpers"
if has /etc/router-app; then
    found=1
    run "rm -rf /etc/router-app /var/run/speedtest.lock"
fi

echo "== Firmware-update keep-list"
# Remove exactly the lines this toolkit added; leave anything else (even if similar) alone.
KEEP_ENTRIES="/etc/vpn-led/ /etc/init.d/vpn-led /etc/rc.d/S96vpn-led
/etc/reboot-log/ /etc/init.d/reboot-log /etc/rc.d/S12reboot-log /etc/rc.d/K01reboot-log
/etc/router-app/
/root/ts/tailscaled.state /root/ts/memguard.sh /root/ts/autoinstall.sh /etc/init.d/tailscale /etc/rc.d/S99tailscale"
PATTERNS=/tmp/toolkit-keep-entries
printf '%s\n' $KEEP_ENTRIES > $PATTERNS
if grep -qxF -f $PATTERNS /etc/sysupgrade.conf; then
    found=1
    grep -xF -f $PATTERNS /etc/sysupgrade.conf | sed 's/^/  would remove line: /' | { [ -n "$DRY" ] && cat || cat >/dev/null; }
    run "grep -vxF -f $PATTERNS /etc/sysupgrade.conf > /tmp/sysupgrade.conf.new; cat /tmp/sysupgrade.conf.new > /etc/sysupgrade.conf; rm -f /tmp/sysupgrade.conf.new"
fi
rm -f $PATTERNS

if [ $found = 0 ]; then echo "Nothing from this toolkit is installed."; exit 0; fi
if [ -n "$DRY" ]; then echo "Dry run: nothing was changed."; exit 0; fi

/etc/init.d/network reload; sleep 3; /etc/init.d/firewall reload >/dev/null 2>&1
echo "Done. The router is back to stock behavior."
EOF
[ -z "$DRY" ] && echo "If you used Tailscale, also remove the router at https://login.tailscale.com/admin/machines"
true
