#!/bin/bash
set -u

DEVICE="${1:-00008140-000C610434EA801C}"
BUNDLE="${2:-app.bamboo3965.leo5976}"
DEST="${3:-/tmp/testflight_diagnostics_live.log}"
DURATION="${4:-900}"

rm -f "$DEST"
end=$((SECONDS + DURATION))
while [ $SECONDS -lt $end ]; do
    tmp="$(mktemp /tmp/tfdiag.XXXXXX)"
    rm -f "$tmp"
    if xcrun devicectl device copy from \
        --device "$DEVICE" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE" \
        --source Documents/TestFlight/diagnostics.log \
        --destination "$tmp" >/dev/null 2>&1; then
        if [ ! -f "$DEST" ] || ! cmp -s "$tmp" "$DEST"; then
            cp "$tmp" "$DEST"
            echo "[$(date '+%H:%M:%S')] diagnostics updated: $(wc -c < "$DEST" | tr -d ' ') bytes"
            tail -n 25 "$DEST"
        fi
    fi
    rm -f "$tmp"
    sleep 5
done
