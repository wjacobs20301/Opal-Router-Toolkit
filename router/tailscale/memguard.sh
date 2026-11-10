#!/bin/sh
# Stops tailscaled if usable memory (MemAvailable + half of free zram swap) drops below 10 MB.
# procd restarts tailscaled after 10s; after 5 stops within an hour it stays off.
sleep 30
while :; do
  if pidof tailscaled >/dev/null; then
    avail=$(awk '/MemAvailable/{a=$2} /SwapFree/{s=$2} END{printf "%d", a+s/2}' /proc/meminfo)
    if [ "${avail:-0}" -lt 10000 ]; then
      logger -t tailscale "low memory (${avail} kB usable), stopping tailscaled"
      killall tailscaled
    fi
  fi
  sleep 10
done
