#!/bin/sh
# Router side of the "Router" Mac menu bar app (GL-SFT1200).
#
# Install:  ssh glrouter 'sh -s' < router/router-app/install.sh
#
#   /etc/router-app/status.sh   prints router status as JSON (reads files/ubus only; cheap)
#   /etc/router-app/speedtest.sh  internet speed test (direct or through the VPN), prints JSON
#   /etc/router-app/action.sh   the only actions the app can run: vpn-on, vpn-off, speedtest-*,
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
printf '"tailscale":{"installed":%s,"running":%s,"health":"%s","ip":"%s"},' \
    "$tinst" "$trun" "$(s "$thealth")" "$(s "$tip")"
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

cat > $D/action.sh <<'ACTION'
#!/bin/sh
# The only actions the Mac app can run on the router.
case "$1" in
    vpn-on)  flock /var/lock/gl-switch.lock /etc/gl-switch.d/vpn.sh on  >/dev/null 2>&1 & ;;
    vpn-off) flock /var/lock/gl-switch.lock /etc/gl-switch.d/vpn.sh off >/dev/null 2>&1 & ;;
    tailscale-restart) /etc/init.d/tailscale restart >/dev/null 2>&1 & ;;
    reboot)  (sleep 2; reboot) >/dev/null 2>&1 & ;;
    speedtest-direct) logger -t router-app "action: $1"; exec /etc/router-app/speedtest.sh direct ;;
    speedtest-vpn)    logger -t router-app "action: $1"; exec /etc/router-app/speedtest.sh vpn ;;
    *) echo "unknown action"; exit 1 ;;
esac
logger -t router-app "action: $1"
echo ok
ACTION
chmod +x $D/action.sh

cat > $D/speedtest.sh <<'SPEED'
#!/bin/sh
# Internet speed test from the router to Cloudflare's speed servers (~25 s). Prints JSON.
#   speedtest.sh direct   the router's own internet line
#   speedtest.sh vpn      through the VPN tunnel (wgclient1)
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

IF=""; PATHNAME=direct
if [ "$1" = vpn ]; then
    [ "$(cat /tmp/wireguard/wgclient1_state 2>/dev/null)" = connected ] || err "VPN is not connected"
    IF="--interface wgclient1"; PATHNAME=vpn
fi
C="curl -s $IF"

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

grep -qx "$D/" /etc/sysupgrade.conf || echo "$D/" >> /etc/sysupgrade.conf
echo "Router app helpers installed."
