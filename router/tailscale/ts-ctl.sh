#!/bin/sh
# Turns Tailscale's connection on or off (Tailscale stays installed).
#   ts-ctl.sh off    disconnect (like `tailscale down`); remembered until the next boot
#   ts-ctl.sh on     connect again
#   ts-ctl.sh boot   called at startup: always connect (clears any "off" from before the reboot)
#
# The "off" choice lives in /tmp, which is wiped at every boot, so the router always
# reconnects to Tailscale when it starts. Settings for `tailscale up` come from
# /root/ts/up-flags (written by the installer).
TS=/root/ts
SOCK=/var/run/tailscale/tailscaled.sock
OFF=/tmp/ts-user-off
CLI="nice -n 19 $TS/tailscale --socket=$SOCK"

wait_socket() {
    i=0; until [ -S $SOCK ] || [ $i -ge 60 ]; do sleep 2; i=$((i + 1)); done
    [ -S $SOCK ]
}

up() {
    # shellcheck disable=SC2046
    $CLI up $(cat $TS/up-flags 2>/dev/null) --timeout=20s >/dev/null 2>&1
}

case "$1" in
    off)
        touch $OFF
        echo off > /tmp/ts-health
        $CLI down >/dev/null 2>&1
        logger -t tailscale "turned off (until turned on again or the router restarts)"
        ;;
    on)
        rm -f $OFF
        wait_socket && up
        logger -t tailscale "turned on"
        ;;
    boot)
        rm -f $OFF
        sleep 20                    # let the network settle first
        wait_socket && up
        ;;
    *) echo "usage: $0 on|off|boot"; exit 1 ;;
esac
