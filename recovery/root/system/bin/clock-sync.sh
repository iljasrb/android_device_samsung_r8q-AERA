#!/system/bin/sh
# Set the recovery clock from a network time reference after WLAN connects.
#
# TWRP's Fixup_Time rewinds the clock to the image's stale timestamp, which
# makes every current TLS certificate "not yet valid". wlan-start.sh seeds the
# clock from the build epoch as a fallback; this service replaces it with the
# current time as soon as DHCP has finished.
#
# The time comes from the HTTP Date header of a well-known anycast resolver.
# The header is UTC, so the result is independent of the recovery timezone and
# matches the PC clock (the PC uses the same network time).

LOG=/tmp/clock-sync.log
: > "$LOG"

log() {
    echo "$(cut -d' ' -f1 /proc/uptime)s $(date -u '+%Y-%m-%dT%H:%M:%SZ') clock-sync: $*" >> "$LOG"
}

# Wait up to 60 seconds for an IPv4 address from DHCP.
i=0
while ! ifconfig wlan0 2>/dev/null | grep -q 'inet addr:'; do
    if [ "$i" -ge 120 ]; then
        log "no IPv4 address on wlan0; clock not synced"
        exit 1
    fi
    sleep 0.5
    i=$((i + 1))
done

log "wlan0 has an IPv4 address; requesting network time"

for host in 1.1.1.1 8.8.8.8 9.9.9.9; do
    header="$(printf 'HEAD / HTTP/1.0\r\nHost: %s\r\n\r\n' "$host" |
        nc -4 -w 5 "$host" 80 2>/dev/null |
        sed -n 's/^[Dd]ate: *//p' | head -n 1 | tr -d '\r')"
    [ -n "$header" ] || continue

    epoch="$(date -u -D '%a, %d %b %Y %H:%M:%S GMT' -d "$header" +%s 2>/dev/null)"
    case "$epoch" in
        ''|*[!0-9]*) continue ;;
    esac
    # Reject a clock before 2024-01-01; a broken header must not rewind us.
    [ "$epoch" -gt 1704067200 ] || continue

    if date -u -s "@$epoch" 2>>"$LOG"; then
        log "clock set from $host: $header"
        exit 0
    fi
done

log "no usable Date header; clock not synced"
exit 1
