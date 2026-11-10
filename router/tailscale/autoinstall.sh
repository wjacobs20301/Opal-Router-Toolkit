#!/bin/sh
# Reinstalls Tailscale's program files and compressed memory (zram) when they're
# missing, e.g. after a firmware update. Started at boot by /etc/init.d/tailscale.
#
# - Waits for internet (up to 10 minutes).
# - Downloads the official Tailscale release pinned below, unpacking as it streams
#   (the archive itself is never stored).
# - Checks each file against the pinned SHA-256 fingerprint; a mismatch is deleted.
# - 3 tries, then gives up until the next boot.
VER=1.104.5
SHA_TAILSCALE=c48aad84fc1f15a030659af803dfe01e73c8424ab0889823d7eec290e04823e9
SHA_TAILSCALED=76930d33a36604901a57bee6a50c5b32f80382812278cda30927bfa51ff83fa5
URL="https://pkgs.tailscale.com/stable/tailscale_${VER}_mipsle.tgz"
TS=/root/ts
DL=$TS/dl
LOCK=/var/run/ts-autoinstall.lock

log() { logger -t tailscale-autoinstall "$*"; }

[ -e $LOCK ] && kill -0 "$(cat $LOCK)" 2>/dev/null && exit 0
echo $$ > $LOCK
trap 'rm -f $LOCK; rm -rf $DL' EXIT

# Wait for internet.
i=0
until ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W3 8.8.8.8 >/dev/null 2>&1; do
    i=$((i + 1))
    [ $i -ge 60 ] && { log "no internet after 10 minutes, will try again next boot"; exit 1; }
    sleep 10
done

# Compressed memory (Tailscale needs the headroom on this router).
if ! opkg list-installed | grep -q "^zram-swap "; then
    if opkg update >/dev/null 2>&1 && opkg install kmod-zram zram-swap >/dev/null 2>&1; then
        /etc/init.d/zram start >/dev/null 2>&1; log "installed zram"
    else
        log "zram install failed (continuing)"
    fi
fi

[ -x $TS/tailscale ] && [ -x $TS/tailscaled ] && exit 0

mkdir -p $TS
for try in 1 2 3; do
    rm -rf $DL; mkdir -p $DL
    log "downloading Tailscale $VER (try $try)"
    # Limits: 15 minutes, 60 MB download (the real archive is ~36 MB).
    if curl -fsSL --connect-timeout 20 --max-time 900 --max-filesize 60000000 "$URL" | \
         head -c 60000000 | \
         tar xzf - -C $DL "tailscale_${VER}_mipsle/tailscale" "tailscale_${VER}_mipsle/tailscaled"; then
        S=$DL/tailscale_${VER}_mipsle
        # Must be plain files (not links), of a sane size, with the pinned fingerprints.
        sane=1
        for f in $S/tailscale $S/tailscaled; do
            if [ ! -f "$f" ] || [ -L "$f" ] || [ "$(wc -c < "$f")" -gt 100000000 ]; then sane=0; fi
        done
        if [ $sane = 1 ] && \
           [ "$(sha256sum $S/tailscale | cut -d' ' -f1)" = "$SHA_TAILSCALE" ] && \
           [ "$(sha256sum $S/tailscaled | cut -d' ' -f1)" = "$SHA_TAILSCALED" ]; then
            chmod +x $S/tailscale $S/tailscaled
            mv $S/tailscale $TS/tailscale
            mv $S/tailscaled $TS/tailscaled
            log "installed Tailscale $VER, starting it"
            /etc/init.d/tailscale start
            exit 0
        fi
        log "download failed checks (fingerprint, file type or size), discarded"
    else
        log "download failed"
    fi
    sleep 30
done
log "giving up until next boot (or run router-tailscale/install.sh from the Mac)"
exit 1
