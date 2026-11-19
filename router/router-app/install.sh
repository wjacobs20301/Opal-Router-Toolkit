#!/bin/sh
# Router side of the "Router" Mac menu bar app (GL-SFT1200).
#
# Install:  ssh glrouter 'sh -s' < router/router-app/install.sh
#
#   /etc/router-app/status.sh   prints router status as JSON (reads files/ubus only; cheap)
#   /etc/router-app/speedtest.sh  internet speed test (direct, VPN, or one connection), prints JSON
#   /etc/router-app/latency.sh  latency test (direct, VPN, or one connection), prints JSON
#   /etc/router-app/wan.sh      load-balanced connections with byte counters, prints JSON
#   /etc/router-app/via.sh      shared helper: send a test through one specific path
#   /www/cgi-bin/routerbar-speed  Mac <-> router throughput test page (50 MB cap)
#   /etc/router-app/action.sh   the only actions the app can run: vpn-on/off, tailscale-on/off, speedtest-*,
#                               tailscale-restart, reboot
# Kept across firmware updates via /etc/sysupgrade.conf.
#
# Uninstall: ssh glrouter 'rm -rf /etc/router-app; sed -i "/router-app/d" /etc/sysupgrade.conf'

set -e
D=/etc/router-app
mkdir -p $D

cat > $D/status.sh <<'STATUS'
#!/bin/sh
# Router status as JSON for the Mac app. Reads files and ubus only.
# JSON-safe string: printable ASCII only, no quotes, backslashes or line breaks.
# (Wi-Fi network names and DHCP hostnames come from other people's devices.)
s() { printf '%s' "$1" | tr -d '\n\r' | sed 's/["\\]//g; s/[^ -~]//g'; }
up=$(cut -d. -f1 /proc/uptime)
set -- $(cat /proc/loadavg); load="$1"
eval "$(awk '/^MemTotal/{print "mt="$2} /^MemAvailable/{print "ma="$2} /^SwapTotal/{print "st="$2} /^SwapFree/{print "sf="$2}' /proc/meminfo)"
disk=$(df -k /overlay | awk 'NR==2{print $4}')

# Internet + upstream connection
internet=false; grep -q online /proc/gl-kmwan/config 2>/dev/null && internet=true
utype=""; udev=""; ussid=""; usig=""
for i in wan wwan tethering secondwan modem_1_1; do
    j=$(ubus call network.interface.$i status 2>/dev/null) || continue
    [ "$(echo "$j" | jsonfilter -e @.up 2>/dev/null)" = "true" ] || continue
    udev=$(echo "$j" | jsonfilter -e @.l3_device 2>/dev/null)
    case $i in
        wan) utype="Ethernet" ;;
        wwan) utype="Wi-Fi"
              info=$(iwinfo "$udev" info 2>/dev/null)
              ussid=$(echo "$info" | sed -n 's/.*ESSID: "\(.*\)".*/\1/p' | head -1)
              usig=$(echo "$info" | sed -n 's/.*Signal: \(-*[0-9]*\) dBm.*/\1/p' | head -1) ;;
        tethering) utype="USB tethering" ;;
        *) utype="Cellular" ;;
    esac
    break
done
gw=$(ip -4 route show default | awk '{print $3; exit}')

# VPN (side switch / dashboard)
vwanted=false; vstate=off; vname=""; vloc=""
i=0
while [ $i -lt 10 ]; do
    if [ "$(uci -q get route_policy.@rule[$i].enabled)" = "1" ]; then
        case "$(uci -q get route_policy.@rule[$i].via_type)" in
            wireguard)
                vwanted=true; p=$(uci -q get route_policy.@rule[$i].peer_id)
                vname=$(uci -q get wireguard.peer_$p.name); vloc=$(uci -q get wireguard.peer_$p.location) ;;
            openvpn) vwanted=true ;;
        esac
    fi
    i=$((i + 1))
done
for f in /tmp/wireguard/wgclient*_state /tmp/ovpnclient/ovpnclient*_state; do
    [ -f "$f" ] || continue
    c=$(cat "$f"); [ "$c" = connected ] && { vstate=connected; break; }; [ "$c" = connecting ] && vstate=connecting
done
[ "$vwanted" = true ] && [ "$vstate" = off ] && vstate=connecting

# Tailscale
trun=false; pidof tailscaled >/dev/null && trun=true
thealth=$(cat /tmp/ts-health 2>/dev/null)
tip=$(ip -4 addr show tailscale0 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); print $2}')
tinst=false; [ -f /root/ts/tailscaled.state ] && tinst=true
twanted=true; [ -e /tmp/ts-user-off ] && twanted=false

# Reboot log
rlast=$(grep '^=== boot' /etc/reboot-log/history.log 2>/dev/null | tail -1 | sed 's/^=== //')
runexp=$(grep -c ': PROBLEM - ' /etc/reboot-log/history.log 2>/dev/null); runexp=${runexp:-0}   # only real problems, not unplugging

printf '{"uptime":%s,"load":"%s","mem_total_kb":%s,"mem_avail_kb":%s,"swap_total_kb":%s,"swap_free_kb":%s,"disk_free_kb":%s,' \
    "$up" "$load" "${mt:-0}" "${ma:-0}" "${st:-0}" "${sf:-0}" "${disk:-0}"
printf '"lan_ip":"%s",' "$(uci -q get network.lan.ipaddr)"
printf '"internet":%s,"upstream":{"type":"%s","device":"%s","ssid":"%s","signal_dbm":"%s","gateway":"%s"},' \
    "$internet" "$(s "$utype")" "$(s "$udev")" "$(s "$ussid")" "$(s "$usig")" "$(s "$gw")"
printf '"vpn":{"wanted":%s,"state":"%s","server":"%s","location":"%s"},' \
    "$vwanted" "$vstate" "$(s "$vname")" "$(s "$vloc")"
printf '"tailscale":{"installed":%s,"running":%s,"wanted":%s,"health":"%s","ip":"%s"},' \
    "$tinst" "$trun" "$twanted" "$(s "$thealth")" "$(s "$tip")"
printf '"reboots":{"last":"%s","unexpected":%s},' "$(s "$rlast")" "$runexp"

# Devices: DHCP leases, marked online if the router has a live ARP entry for them.
printf '"devices":['
first=1
while read -r exp mac ip host rest; do
    [ -n "$mac" ] || continue
    on=false; awk -v ip="$ip" '$1==ip && $3=="0x2" {f=1} END{exit !f}' /proc/net/arp && on=true
    [ "$host" = "*" ] && host=""
    [ $first = 1 ] || printf ','; first=0
    printf '{"mac":"%s","ip":"%s","name":"%s","online":%s,"lease_expires":%s}' \
        "$(s "$mac")" "$(s "$ip")" "$(s "$host")" "$on" "${exp:-0}"
done < /tmp/dhcp.leases
printf ']}\n'
STATUS
chmod +x $D/status.sh

cat > $D/via.sh <<'VIA'
# Sourced by speedtest.sh / latency.sh: send test traffic through one specific path.
#   via_setup direct | vpn | wan:<interface>     sets VIA_CURL, VIA_PING (or VIA_ERR)
#   via_cleanup                                   removes any temporary routing
# For wan:<interface> it adds a temporary source-based route (rule priority 2, table 990),
# so the test leaves through that connection even while load balancing is on.
VIA_TABLE=990
VIA_RULE=""
via_setup() {
    VIA_CURL=""; VIA_PING=""; VIA_ERR=""
    case "$1" in
        direct) return 0 ;;
        vpn)
            [ "$(cat /tmp/wireguard/wgclient1_state 2>/dev/null)" = connected ] || { VIA_ERR="VPN is not connected"; return 1; }
            VIA_CURL="--interface wgclient1"; VIA_PING="-I wgclient1"; return 0 ;;
        wan:*)
            i=${1#wan:}
            case "$i" in *[!a-z0-9_]*|"") VIA_ERR="Unknown connection"; return 1 ;; esac
            uci -q get kmwan.$i >/dev/null || [ "$(uci -q show kmwan | grep -c "interface='$i'")" -gt 0 ] || { VIA_ERR="Unknown connection"; return 1; }
            j=$(ubus call network.interface.$i status 2>/dev/null) || { VIA_ERR="Unknown connection"; return 1; }
            [ "$(echo "$j" | jsonfilter -e @.up)" = true ] || { VIA_ERR="That connection is not connected"; return 1; }
            dev=$(echo "$j" | jsonfilter -e @.l3_device)
            ip=$(echo "$j" | jsonfilter -e '@["ipv4-address"][0].address')
            gw=$(echo "$j" | jsonfilter -e '@.route[0].nexthop')
            [ -n "$dev" ] && [ -n "$ip" ] || { VIA_ERR="That connection has no address"; return 1; }
            ip route flush table $VIA_TABLE 2>/dev/null
            if [ -n "$gw" ] && [ "$gw" != "0.0.0.0" ]; then
                ip route add default via "$gw" dev "$dev" table $VIA_TABLE || { VIA_ERR="Couldn't route through it"; return 1; }
            else
                ip route add default dev "$dev" table $VIA_TABLE || { VIA_ERR="Couldn't route through it"; return 1; }
            fi
            ip rule add from "$ip" lookup $VIA_TABLE priority 2 && VIA_RULE="$ip"
            VIA_CURL="--interface $ip"; VIA_PING="-I $ip"; return 0 ;;
        *) VIA_ERR="Unknown path"; return 1 ;;
    esac
}
via_cleanup() {
    [ -n "$VIA_RULE" ] && ip rule del from "$VIA_RULE" lookup $VIA_TABLE priority 2 2>/dev/null
    ip route flush table $VIA_TABLE 2>/dev/null
    VIA_RULE=""
}
VIA

cat > $D/latency.sh <<'LAT'
#!/bin/sh
# Latency test (8 pings to 1.1.1.1) through one path. Prints JSON.
#   latency.sh direct | vpn | wan:<interface>
err() { printf '{"error":"%s"}\n' "$1"; exit 0; }
. /etc/router-app/via.sh
via_setup "${1:-direct}" || err "$VIA_ERR"
trap via_cleanup EXIT
# shellcheck disable=SC2086
out=$(ping -c 8 -W 2 $VIA_PING 1.1.1.1 2>&1)
echo "$out" | awk -v path="${1:-direct}" '
    /time=/ { sub(/.*time=/, ""); t[n++] = $1 + 0 }
    /packets transmitted/ { tx = $1; rx = $4 }
    END {
        if (tx == 0) { print "{\"error\":\"Ping failed\"}"; exit }
        if (n == 0) { printf "{\"path\":\"%s\",\"sent\":%d,\"received\":0,\"loss_pct\":100}\n", path, tx; exit }
        mn = t[0]; mx = t[0]; s = 0; j = 0
        for (i = 0; i < n; i++) { s += t[i]; if (t[i] < mn) mn = t[i]; if (t[i] > mx) mx = t[i] }
        for (i = 1; i < n; i++) { d = t[i] - t[i-1]; j += (d < 0 ? -d : d) }
        printf "{\"path\":\"%s\",\"sent\":%d,\"received\":%d,\"loss_pct\":%d,\"min_ms\":%.1f,\"avg_ms\":%.1f,\"max_ms\":%.1f,\"jitter_ms\":%.1f}\n",
            path, tx, rx, (tx - rx) * 100 / tx, mn, s / n, mx, (n > 1 ? j / (n - 1) : 0)
    }'
LAT
chmod +x $D/latency.sh

cat > $D/wan.sh <<'WAN'
#!/bin/sh
# Every load-balanced connection with its state and byte counters, as JSON. Cheap (no
# iwinfo), so RouterBar can poll it every couple of seconds while its window is open.
s() { printf '%s' "$1" | tr -d '\n\r' | sed 's/["\\]//g; s/[^ -~]//g'; }
mode=$(uci -q get kmwan.global.mode)
printf '{"mode":"%s","uptime":%s,"interfaces":[' "$(s "$mode")" "$(cut -d. -f1 /proc/uptime)"
first=1
for m in $(uci -q show kmwan | sed -n "s/^kmwan\.\([^.=]*\)=member$/\1/p"); do
    i=$(uci -q get kmwan.$m.interface); [ -n "$i" ] || continue
    j=$(ubus call network.interface.$i status 2>/dev/null) || continue
    up=$(echo "$j" | jsonfilter -e @.up); [ "$up" = true ] || up=false
    dev=$(echo "$j" | jsonfilter -e @.l3_device)
    ip=$(echo "$j" | jsonfilter -e '@["ipv4-address"][0].address')
    gw=$(echo "$j" | jsonfilter -e '@.route[0].nexthop')
    st=$(awk -v n="$i" '$1 == n { print $4 }' /proc/gl-kmwan/status 2>/dev/null)
    set -- $(awk -v d="$dev:" '{ sub(/^ +/, "") } index($0, d) == 1 { sub(d, ""); print $1, $9 }' /proc/net/dev)
    rx=${1:-0}; tx=${2:-0}
    case "$i" in
        wan) type=Ethernet ;; wwan) type=Repeater ;; tethering) type=Tethering ;;
        secondwan) type="Ethernet 2" ;; modem*) type=Cellular ;; *) type=$i ;;
    esac
    [ $first = 1 ] || printf ','; first=0
    printf '{"name":"%s","type":"%s","up":%s,"state":"%s","device":"%s","ip":"%s","gateway":"%s","weight":%s,"disabled":%s,"rx_bytes":%s,"tx_bytes":%s}' \
        "$(s "$i")" "$(s "$type")" "$up" "$(s "$st")" "$(s "$dev")" "$(s "$ip")" "$(s "$gw")" \
        "$(uci -q get kmwan.$m.weight || echo 1)" "$([ "$(uci -q get kmwan.$m.disabled)" = 1 ] && echo true || echo false)" "$rx" "$tx"
done
printf ']}\n'
WAN
chmod +x $D/wan.sh

# Mac -> router throughput test page (GET: download zeros, POST: upload discarded). 50 MB cap.
mkdir -p /www/cgi-bin
cat > /www/cgi-bin/routerbar-speed <<'CGI'
#!/bin/sh
max=50000000
if [ "$REQUEST_METHOD" = POST ]; then
    n=${CONTENT_LENGTH:-0}; case "$n" in *[!0-9]*|"") n=0 ;; esac
    [ "$n" -gt $max ] && n=$max
    head -c "$n" > /dev/null
    printf 'Content-Type: text/plain\r\nCache-Control: no-store\r\n\r\nok\n'
    exit 0
fi
n=$(echo "$QUERY_STRING" | sed -n 's/^.*bytes=\([0-9][0-9]*\).*$/\1/p')
[ -z "$n" ] && n=1000000
[ "$n" -gt $max ] && n=$max
printf 'Content-Type: application/octet-stream\r\nContent-Length: %s\r\nCache-Control: no-store\r\n\r\n' "$n"
head -c "$n" /dev/zero
CGI
chmod 755 /www/cgi-bin/routerbar-speed

cat > $D/action.sh <<'ACTION'
#!/bin/sh
# The only actions the Mac app can run on the router.
LOCK=/var/lock/gl-switch.lock
vpn_wanted() {
    i=0
    while [ $i -lt 10 ]; do
        [ "$(uci -q get route_policy.@rule[$i].enabled)" = "1" ] && return 0
        i=$((i + 1))
    done
    return 1
}
vpn_busy() {
    { [ -e $LOCK ] && ! flock -n $LOCK true; } || pgrep -f "/etc/init.d/vpn-client" >/dev/null
}
case "$1" in
    vpn-on|vpn-off)
        want=on; [ "$1" = vpn-off ] && want=off
        # Already in that state: do nothing (GL.iNet restarts its whole VPN system otherwise).
        if [ $want = on ] && vpn_wanted; then echo "already on"; exit 0; fi
        if [ $want = off ] && ! vpn_wanted; then echo "already off"; exit 0; fi
        # Never stack VPN switches: they're heavy on this router.
        if vpn_busy; then echo "busy"; exit 0; fi
        flock -n $LOCK /etc/gl-switch.d/vpn.sh $want >/dev/null 2>&1 &
        ;;
    tailscale-on)  /root/ts/ts-ctl.sh on  >/dev/null 2>&1 & ;;
    tailscale-off) /root/ts/ts-ctl.sh off >/dev/null 2>&1 & ;;
    tailscale-restart) /etc/init.d/tailscale restart >/dev/null 2>&1 & ;;
    reboot)  (sleep 2; reboot) >/dev/null 2>&1 & ;;
    speedtest-direct) logger -t router-app "action: $1"; exec /etc/router-app/speedtest.sh direct ;;
    speedtest-vpn)    logger -t router-app "action: $1"; exec /etc/router-app/speedtest.sh vpn ;;
    speedtest-wan-*)  i=${1#speedtest-wan-}; case "$i" in *[!a-z0-9_]*|"") echo "unknown action"; exit 1 ;; esac
                      logger -t router-app "action: $1"; exec /etc/router-app/speedtest.sh "wan:$i" ;;
    latency-direct)   exec /etc/router-app/latency.sh direct ;;
    latency-vpn)      exec /etc/router-app/latency.sh vpn ;;
    latency-wan-*)    i=${1#latency-wan-}; case "$i" in *[!a-z0-9_]*|"") echo "unknown action"; exit 1 ;; esac
                      exec /etc/router-app/latency.sh "wan:$i" ;;
    *) echo "unknown action"; exit 1 ;;
esac
logger -t router-app "action: $1"
echo ok
ACTION
chmod +x $D/action.sh

cat > $D/speedtest.sh <<'SPEED'
#!/bin/sh
# Internet speed test from the router to Cloudflare's speed servers (~25 s). Prints JSON.
#   speedtest.sh direct      the router's normal internet route
#   speedtest.sh vpn         through the VPN tunnel (wgclient1)
#   speedtest.sh wan:<name>  through one load-balanced connection (wan, wwan, tethering, ...)
# Download: 4 parallel 25 MB transfers. Upload: 2 parallel 12 MB streamed transfers.
# Also records how busy the CPU was (the router can cap HTTPS speed around 90-100 Mbit/s).
URL=https://speed.cloudflare.com
LOCK=/var/run/speedtest.lock
OUT=/tmp/speedtest.$$
err() { printf '{"error":"%s"}\n' "$1"; rm -rf $OUT; exit 0; }

[ -e $LOCK ] && kill -0 "$(cat $LOCK)" 2>/dev/null && err "A speed test is already running"
echo $$ > $LOCK
trap 'rm -f $LOCK; rm -rf $OUT' EXIT
mkdir -p $OUT

. /etc/router-app/via.sh
via_setup "${1:-direct}" || err "$VIA_ERR"
trap 'via_cleanup; rm -f $LOCK; rm -rf $OUT' EXIT
PATHNAME="${1:-direct}"
C="curl -s $VIA_CURL"

now() { cut -d' ' -f1 /proc/uptime; }
cpu() { awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat; }
busy() { set -- $(cpu); echo $(( 100 - 100 * ($2 - $I0) / ($1 - $T0 + 1) )); }

colo=$($C --max-time 6 $URL/cdn-cgi/trace | sed -n 's/^colo=//p')
[ -n "$colo" ] || err "Can't reach the speed test server"

# Latency: TCP connect time, 6 samples.
for i in 1 2 3 4 5 6; do
    $C -o /dev/null --max-time 4 -w '%{time_connect}\n' "$URL/__down?bytes=0"
done > $OUT/ping
eval "$(awk '$1>0 {v[n++]=$1*1000} END {
    if (n == 0) { print "ping=0 jitter=0"; exit }
    s = 0; for (i = 0; i < n; i++) s += v[i]
    j = 0; for (i = 1; i < n; i++) { d = v[i] - v[i-1]; j += (d < 0 ? -d : d) }
    printf "ping=%.0f jitter=%.0f\n", s / n, (n > 1 ? j / (n - 1) : 0) }' $OUT/ping)"

# Download
set -- $(cpu); T0=$1; I0=$2; s=$(now)
for i in 1 2 3 4; do
    $C -o /dev/null --max-time 12 -w '%{size_download}\n' "$URL/__down?bytes=25000000" > $OUT/d$i &
done
wait
e=$(now); dcpu=$(busy)
down=$(cat $OUT/d* | awk -v s=$s -v e=$e '{b+=$1} END{ if (e>s) printf "%.1f", b*8/(e-s)/1e6; else print 0 }')

# Upload (streamed with -T, so the data never has to sit in the router's memory)
set -- $(cpu); T0=$1; I0=$2; s=$(now)
for i in 1 2; do
    dd if=/dev/zero bs=64k count=192 2>/dev/null | \
        $C -o /dev/null --max-time 12 -X POST -H 'Content-Type: application/octet-stream' \
            -T - -w '%{size_upload}\n' "$URL/__up" > $OUT/u$i &
done
wait
e=$(now); ucpu=$(busy)
up=$(cat $OUT/u* | awk -v s=$s -v e=$e '{b+=$1} END{ if (e>s) printf "%.1f", b*8/(e-s)/1e6; else print 0 }')

logger -t router-app "speedtest $PATHNAME: down ${down} up ${up} Mbit/s ping ${ping} ms"
printf '{"path":"%s","server":"%s","ping_ms":%s,"jitter_ms":%s,"download_mbps":%s,"upload_mbps":%s,"cpu_download":%s,"cpu_upload":%s}\n' \
    "$PATHNAME" "$colo" "$ping" "$jitter" "$down" "$up" "$dcpu" "$ucpu"
SPEED
chmod +x $D/speedtest.sh

for p in "$D/" /www/cgi-bin/routerbar-speed; do
    grep -qx "$p" /etc/sysupgrade.conf || echo "$p" >> /etc/sysupgrade.conf
done
echo "Router app helpers installed."
