#!/system/bin/sh
# Hand the vendor partition back to the ROM installers.
#
# The WLAN stack mounts the real vendor at /tmp/wlan-vendor and overlays the
# kernel's firmware folder with a tmpfs. TWRP's zip installer refuses to run
# while a vendor mount is busy, so stop the WLAN stack and detach the private
# mounts. The recovery's own /vendor (the AERA supplicant and the crypto/GPU
# libraries) is never mounted and is left alone.
#
# Trigger: setprop aera.release.mounts 1
LOG=/tmp/release-mounts.log
: > "$LOG"
# Clear the completion flag before starting, so an install that races this
# script cannot mistake a previous release for the current one.
setprop aera.mounts.released 0
log() {
    echo "release-mounts: $*" >> "$LOG"
    echo "release-mounts: $*" > /dev/kmsg 2>/dev/null
}

# The WLAN stack runs from the private vendor mount; stop it first.
for svc in wpa_supplicant macloader cnss-daemon qrtr-ns; do
    setprop ctl.stop "$svc"
done
sleep 0.5

for mnt in /vendor/firmware_mnt /tmp/apnhlos /tmp/wlan-vendor; do
    if grep -q " $mnt " /proc/mounts; then
        if umount "$mnt" 2>/dev/null; then
            log "unmounted $mnt"
        else
            umount -l "$mnt" 2>/dev/null
            log "lazy-unmounted $mnt"
        fi
    fi
done

# Release any /vendor mount TWRP itself made (the recovery's own /vendor is
# not a mount, so this only touches a real vendor mount).
for mnt in $(grep ' /vendor' /proc/mounts | awk '{print $2}' | sort -r); do
    umount "$mnt" 2>/dev/null && log "unmounted $mnt"
done

log "remaining vendor mounts: $(grep -c ' /vendor' /proc/mounts)"
setprop aera.mounts.released 1
