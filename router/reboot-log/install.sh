#!/bin/sh
# GL-SFT1200 reboot log: records why the router restarted.
#
# Install:  ssh glrouter 'sh -s' < router/reboot-log/install.sh
# Read the history:            ssh glrouter cat /etc/reboot-log/history.log
#
# Each boot is labeled:
#   CLEAN      a normal reboot (Reboot button, dashboard, `reboot`)
#   UNPLUGGED  power was cut while the router was healthy (normal for a travel router;
#              never flagged)
#   UPDATE     the firmware version changed (a firmware update)
#   PROBLEM    power was cut AND the last 5 minutes showed trouble: very low memory,
#              very high CPU load, or out-of-memory / crash / "low memory" messages.
#              Most likely a freeze (hardware watchdog reset) or a crash. Only these are flagged.
#
# Files (all in /etc/reboot-log/, kept across firmware updates):
#   heartbeat      latest snapshot, every 30s (time, memory, load, Tailscale, top processes)
#   recent         the last 10 snapshots' key numbers (5 minutes)
#   syslog-latest  copy of the system log, every 5 minutes and at clean shutdown
#   clean          marker written only on a clean shutdown
#   firmware       firmware version seen at the last boot
#   history.log    one entry per boot with its label and reason
#   prev-1..3/     evidence from the last 3 PROBLEM restarts
#
# Uninstall:
#   ssh glrouter '/etc/init.d/reboot-log stop; /etc/init.d/reboot-log disable; \
#     rm -rf /etc/reboot-log /etc/init.d/reboot-log; sed -i "/reboot-log/d" /etc/sysupgrade.conf'

set -e
D=/etc/reboot-log
mkdir -p $D
chmod 700 $D        # logs and snapshots: root only

cat > $D/monitor.sh <<'MON'
#!/bin/sh
# Snapshot every 30s, syslog copy every 5 minutes (written to flash).
D=/etc/reboot-log
WARN='low memory|out of memory|oom-kill|killed process|kernel panic|soft lockup|hung_task|blocked for more than'
n=0
while :; do
    usable=$(awk '/MemAvailable/{a=$2} /SwapFree/{s=$2} END{printf "%d", a + s / 2}' /proc/meminfo)
    load1=$(cut -d' ' -f1 /proc/loadavg)
    up=$(cut -d. -f1 /proc/uptime)
    p=$(pidof tailscaled)
    warn=$(logread | grep -ciE "$WARN")
    {
        echo "time=$(date '+%Y-%m-%d %H:%M:%S') uptime=${up}s load=$(cut -d' ' -f1-3 /proc/loadavg)"
        awk '/MemTotal|MemAvailable|SwapTotal|SwapFree/{printf "%s=%dMB ", $1, $2/1024} END{print ""}' /proc/meminfo
        [ -n "$p" ] && echo "tailscaled_rss=$(awk '/VmRSS/{print $2}' /proc/$p/status 2>/dev/null)kB" || echo "tailscaled=not running"
        echo "ts-health=$(cat /tmp/ts-health 2>/dev/null) vpn=$(cat /tmp/wireguard/wgclient1_state 2>/dev/null) warnings=$warn"
        echo "top memory:"
        for s in /proc/[0-9]*/status; do
            awk '/^Name/{n=$2} /^VmRSS/{print $2, n}' "$s" 2>/dev/null
        done | sort -rn | head -5
    } > $D/heartbeat.tmp && mv $D/heartbeat.tmp $D/heartbeat
    { cat $D/recent 2>/dev/null
      echo "up=$up usable_kb=$usable load1=$load1 warn=$warn time=$(date '+%H:%M:%S')"
    } | tail -10 > $D/recent.tmp && mv $D/recent.tmp $D/recent
    n=$((n + 1))
    if [ $((n % 10)) -eq 1 ]; then
        logread | tail -300 > $D/syslog.tmp && mv $D/syslog.tmp $D/syslog-latest
    fi
    sleep 30
done
MON
chmod +x $D/monitor.sh

cat > $D/classify.sh <<'CLS'
#!/bin/sh
# Prints "LABEL|reason" for the previous shutdown. Used at boot by /etc/init.d/reboot-log.
D=/etc/reboot-log
fw_now="$(cat /etc/glversion 2>/dev/null) $(cat /etc/openwrt_version 2>/dev/null)"
fw_old="$(cat $D/firmware 2>/dev/null)"

if [ -n "$fw_old" ] && [ "$fw_old" != "$fw_now" ]; then
    echo "UPDATE|firmware changed from $fw_old to $fw_now"; exit 0
fi
if [ -f $D/clean ]; then
    echo "CLEAN|normal reboot at $(cat $D/clean)"; exit 0
fi
# Power was cut. Was the router in trouble in its last 5 minutes?
[ -f $D/recent ] || { echo "UNPLUGGED|no recent data; assumed unplugged"; exit 0; }
awk '
    { for (i = 1; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
      if (NR == 1) w0 = v["warn"]
      if (v["usable_kb"] + 0 < 15000) low = v["usable_kb"]
      if (v["load1"] + 0 >= 8) hi = v["load1"]
      w1 = v["warn"]; last = $0 }
    END {
      r = ""
      if (low != "") r = r "memory fell to " int(low / 1024) " MB; "
      if (hi != "")  r = r "CPU load reached " hi "; "
      if (w1 + 0 > w0 + 0) r = r sprintf("%d crash/low-memory messages in the log; ", w1 - w0)
      if (r != "") print "PROBLEM|" r "likely froze (watchdog reset) or crashed"
      else         print "UNPLUGGED|router was healthy right before (power cut or unplugged)"
    }' $D/recent
CLS
chmod +x $D/classify.sh

cat > /etc/init.d/reboot-log <<'INIT'
#!/bin/sh /etc/rc.common
# Records the cause of each restart (see /etc/reboot-log/).
START=12
STOP=01
D=/etc/reboot-log

start() {
    mkdir -p $D
    if [ -f $D/heartbeat ]; then
        res=$($D/classify.sh)
        label=${res%%|*}; reason=${res#*|}
        if [ "$label" = PROBLEM ]; then
            # Keep evidence from the last 3 problem restarts.
            rm -rf $D/prev-3; [ -d $D/prev-2 ] && mv $D/prev-2 $D/prev-3
            [ -d $D/prev-1 ] && mv $D/prev-1 $D/prev-2
            mkdir -p $D/prev-1
            cp $D/heartbeat $D/recent $D/syslog-latest $D/prev-1/ 2>/dev/null
        fi
        n=$(grep -c '^=== boot' $D/history.log 2>/dev/null); n=${n:-0}
        {
            echo "=== boot #$((n + 1)) (detected $(date '+%Y-%m-%d %H:%M:%S'), clock may lag until NTP sync): $label - $reason"
            if [ "$label" = PROBLEM ]; then
                echo "    last 5 minutes:"; sed 's/^/      /' $D/recent
                echo "    last snapshot:";  sed 's/^/      /' $D/heartbeat
            fi
        } >> $D/history.log
        tail -400 $D/history.log > $D/history.tmp && mv $D/history.tmp $D/history.log
        logger -t reboot-log "previous shutdown: $label - $reason"
    fi
    rm -f $D/clean $D/recent
    echo "$(cat /etc/glversion 2>/dev/null) $(cat /etc/openwrt_version 2>/dev/null)" > $D/firmware
    start-stop-daemon -S -b -m -p /var/run/reboot-log.pid -x $D/monitor.sh
}

stop() {
    start-stop-daemon -K -p /var/run/reboot-log.pid >/dev/null 2>&1
    rm -f /var/run/reboot-log.pid
    logread | tail -300 > $D/syslog-latest
    date '+%Y-%m-%d %H:%M:%S' > $D/clean
    sync
}
INIT
chmod +x /etc/init.d/reboot-log
/etc/init.d/reboot-log enable

for p in /etc/reboot-log/ /etc/init.d/reboot-log /etc/rc.d/S12reboot-log /etc/rc.d/K01reboot-log; do
    grep -qx "$p" /etc/sysupgrade.conf || echo "$p" >> /etc/sysupgrade.conf
done

# Restart cleanly (a reinstall is recorded as a CLEAN entry, not a false alarm).
[ -f /var/run/reboot-log.pid ] && /etc/init.d/reboot-log stop
/etc/init.d/reboot-log start
echo "Reboot log: installed and running."
