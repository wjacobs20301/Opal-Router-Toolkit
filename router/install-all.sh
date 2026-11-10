#!/bin/sh
# Installs every router component. Run from anywhere:
#   sh router/install-all.sh
#   ROUTER=root@192.168.8.1 sh router/install-all.sh
set -e
cd "$(dirname "$0")"
R=${ROUTER:-glrouter}
SSH="ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa"

echo "== VPN status LED";        $SSH "$R" 'sh -s' < vpn-led/install.sh
echo "== Reboot log";            $SSH "$R" 'sh -s' < reboot-log/install.sh
echo "== Router helpers";        $SSH "$R" 'sh -s' < router-app/install.sh
echo "== Tailscale";             ROUTER="$R" sh tailscale/install.sh
echo "Done."
