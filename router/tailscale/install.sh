#!/bin/sh
# Installs Tailscale on a GL.iNet GL-SFT1200 (Opal), run from a computer that can SSH to it.
#
#   sh install.sh                      router reachable as "glrouter" (see docs/ssh-setup.md)
#   ROUTER=root@192.168.8.1 sh install.sh
#   REINSTALL=1 sh install.sh          re-download the program files too
#
# Safe to re-run at any time. What it sets up on the router:
#   /root/ts/tailscale, tailscaled  official Tailscale release for mipsle, downloaded BY THE ROUTER
#                                   from pkgs.tailscale.com and checked against pinned SHA-256
#                                   fingerprints (see autoinstall.sh)
#   /etc/init.d/tailscale           starts at boot, restarts it if it stops; if the program files are
#                                   missing (e.g. after a firmware update) it reinstalls them itself
#   /root/ts/memguard.sh            stops tailscaled if usable memory drops below 10 MB
#   zram-swap                       compressed memory (Tailscale needs the headroom on 128 MB)
#   network + firewall "tailscale"  Tailscale <-> the router's LAN in both directions
#                                   (LAN -> Tailscale is address-translated to the router)
#   advertised route                the router's LAN subnet (approve once in the Tailscale admin page)
#
# Kept across firmware updates ("Keep Settings"): login state, init script, memory guard,
# auto-reinstaller, network/firewall config. The program files and zram are not kept
# (too big for the upgrade); they are reinstalled automatically on the first boot with internet.
#
# Uninstall:
#   ssh glrouter '/etc/init.d/tailscale stop; /etc/init.d/tailscale disable; rm -rf /root/ts /etc/init.d/tailscale; \
#     uci delete network.tailscale; uci delete firewall.tailscale; uci delete firewall.tailscale_to_lan; \
#     uci delete firewall.lan_to_tailscale; uci commit network; uci commit firewall; \
#     sed -i "/tailscale\|\/root\/ts/d" /etc/sysupgrade.conf; /etc/init.d/network reload; /etc/init.d/firewall reload'
#   then remove the machine in https://login.tailscale.com/admin/machines

set -e
cd "$(dirname "$0")"
R=${ROUTER:-glrouter}
SSH="ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa"
SCP="scp -O -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa"

echo "Copying scripts to the router..."
$SSH "$R" 'mkdir -p /root/ts; rm -f /root/ts/*.new'
$SCP memguard.sh autoinstall.sh tailscale.init "$R:/root/ts/"

# Only a fixed flag (never the raw environment value) goes into the remote command.
RE=""; [ -n "${REINSTALL:-}" ] && RE=1
$SSH "$R" "REINSTALL=$RE sh -s" <<'EOF'
set -e
mv /root/ts/tailscale.init /etc/init.d/tailscale
chmod +x /root/ts/memguard.sh /root/ts/autoinstall.sh /etc/init.d/tailscale

# Network interface + firewall zone
uci -q get network.tailscale >/dev/null || {
  uci set network.tailscale=interface
  uci set network.tailscale.proto=none
  uci set network.tailscale.ifname=tailscale0
  uci commit network; }
uci -q get firewall.tailscale >/dev/null || {
  uci set firewall.tailscale=zone
  uci set firewall.tailscale.name=tailscale
  uci set firewall.tailscale.network=tailscale
  uci set firewall.tailscale.input=ACCEPT
  uci set firewall.tailscale.output=ACCEPT
  uci set firewall.tailscale.forward=REJECT
  uci set firewall.tailscale_to_lan=forwarding
  uci set firewall.tailscale_to_lan.src=tailscale
  uci set firewall.tailscale_to_lan.dest=lan
  uci commit firewall; }
# Devices on the router's network can reach Tailscale devices (seen as coming from the router).
uci -q get firewall.lan_to_tailscale >/dev/null || {
  uci set firewall.lan_to_tailscale=forwarding
  uci set firewall.lan_to_tailscale.src=lan
  uci set firewall.lan_to_tailscale.dest=tailscale; }
uci set firewall.tailscale.masq=1
uci set firewall.tailscale.mtu_fix=1
uci commit firewall

# Keep-list for firmware updates (small files only)
for p in /root/ts/tailscaled.state /root/ts/memguard.sh /root/ts/autoinstall.sh /etc/init.d/tailscale /etc/rc.d/S99tailscale; do
  grep -qx "$p" /etc/sysupgrade.conf || echo "$p" >> /etc/sysupgrade.conf
done
/etc/init.d/tailscale enable

if [ -n "$REINSTALL" ]; then
  /etc/init.d/tailscale stop 2>/dev/null || true
  i=0; while pidof tailscaled >/dev/null && [ $i -lt 30 ]; do sleep 1; i=$((i+1)); done
  rm -f /root/ts/tailscale /root/ts/tailscaled
fi

if [ -x /root/ts/tailscaled ] && [ -x /root/ts/tailscale ]; then
  echo "Program files present; restarting Tailscale..."
  /etc/init.d/tailscale restart
else
  echo "Downloading and verifying Tailscale on the router (a few minutes)..."
  /root/ts/autoinstall.sh || { echo "Download failed; see: logread -e tailscale-autoinstall"; exit 1; }
fi
/etc/init.d/network reload; sleep 3; /etc/init.d/firewall reload >/dev/null 2>&1

# The router's own LAN subnet, e.g. 192.168.8.0/24
LAN=$(ip -4 route show dev br-lan scope link | awk '{print $1; exit}')
T="/root/ts/tailscale --socket=/var/run/tailscale/tailscaled.sock"
echo "Waiting for Tailscale to start (can take a minute on this router)..."
i=0; until [ -S /var/run/tailscale/tailscaled.sock ] || [ $i -ge 40 ]; do sleep 3; i=$((i+1)); done
sleep 10
if $T status --json 2>/dev/null | grep -q '"BackendState": "NeedsLogin"'; then
  $T up --netfilter-mode=off --accept-dns=false --hostname="$(uci -q get system.@system[0].hostname | tr 'A-Z' 'a-z')" \
        --advertise-routes="$LAN" --timeout=5s >/dev/null 2>&1 || true
  echo "Sign in at: $($T status --json | grep -oE 'https://login.tailscale.com/[^"]+' | head -1)"
  echo "Then approve the $LAN route in https://login.tailscale.com/admin/machines"
else
  $T set --advertise-routes="$LAN"
  echo "Tailscale is up (sharing $LAN):"; $T status | head -1
fi
EOF
