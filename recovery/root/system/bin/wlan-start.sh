#!/system/bin/sh
# Bring up the built-in QCA6390 WLAN stack in recovery.
#
# The kernel is monolithic: the host driver is built in and is asked to load
# by writing ON to /dev/wlan. The chip's firmware, the daemons and the configs
# are on the vendor partition. The vendor is mounted at a private path, not at
# /vendor: the recovery's own /vendor holds the AERA supplicant and the
# crypto/GPU libraries, and the installers expect /vendor to be free.
#
# The kernel's firmware_class.path is the modem's image folder
# (/vendor/firmware_mnt/image), which is where the IPA firmware lives. That
# directory is overlaid with a tmpfs of symlinks to the real apnhlos image,
# plus a qca6390 symlink to the vendor's WLAN images, so both the IPA and the
# WLAN firmware load.
#
# Reference: Skyward r8q (devices/r8q.toml, crates/skyward/src/wlan.rs) and
# the bronco recovery's docs/wifi-support.md.

LOG=/tmp/wlan-start.log
: > "$LOG"

# TWRP's Fixup_Time resets the clock to the image's 2020 timestamp after init.
# Re-seed it once recovery is up so GnuTLS does not reject current TLS
# certificates as "not yet valid" (the RTC itself is not writable here).
# ro.build.date is a human-readable string that toybox date cannot parse, and
# TWRP zeroes ro.build.date.utc, so use the epoch it preserves in
# ro.build.date.utc_aera.
BUILD_EPOCH="$(getprop ro.build.date.utc_aera)"
[ -n "$BUILD_EPOCH" ] || BUILD_EPOCH="$(getprop ro.build.date.utc)"
case "$BUILD_EPOCH" in
    ''|0|*[!0-9]*) BUILD_EPOCH="" ;;
esac
if [ -n "$BUILD_EPOCH" ]; then
    date -u -s "@$BUILD_EPOCH" 2>>"$LOG" || true
else
    echo "wlan-start: no build epoch; clock not re-seeded" >> "$LOG"
fi
log() {
    echo "$(cut -d' ' -f1 /proc/uptime) wlan-start: $*" >> "$LOG"
    echo "wlan-start: $*" > /dev/kmsg 2>/dev/null
}

VENDOR=/tmp/wlan-vendor
APNHLOS=/tmp/apnhlos
LIBKT=/tmp/libkt
FW=/vendor/firmware_mnt

# Already up: just make sure the supplicant is running.
if [ -e /sys/class/net/wlan0 ]; then
    log "wlan0 already present"
    ifconfig wlan0 up 2>>"$LOG"
    setprop ctl.start wpa_supplicant
    exit 0
fi

# 1. Mount the real vendor read-only at a private path.
mkdir -p "$VENDOR"
if ! grep -q " $VENDOR " /proc/mounts; then
    for dev in /dev/block/mapper/vendor /dev/block/bootdevice/by-name/vendor /dev/block/dm-1; do
        [ -e "$dev" ] || continue
        mount -o ro "$dev" "$VENDOR" 2>>"$LOG" && break
    done
fi
if ! grep -q " $VENDOR " /proc/mounts; then
    log "cannot mount the vendor partition"
    exit 1
fi
log "vendor mounted"
# The mount is back: a later install must run release-mounts again instead of
# trusting a stale "released" property from an earlier install.
setprop aera.mounts.released 0

# 2. The kernel's firmware path is the modem's image folder. Mount apnhlos
#    privately and overlay that folder with a tmpfs of symlinks: the IPA
#    firmware comes from apnhlos, the WLAN images from the vendor.
mkdir -p "$APNHLOS"
if ! grep -q " $APNHLOS " /proc/mounts; then
    mount -o ro /dev/block/bootdevice/by-name/apnhlos "$APNHLOS" 2>>"$LOG"
fi
log "apnhlos mounted"
umount "$FW" 2>/dev/null
log "fw unmounted"
mkdir -p "$FW"
mount -t tmpfs tmpfs "$FW" 2>>"$LOG"
log "tmpfs mounted"
mkdir -p "$FW/image"
for f in "$APNHLOS"/image/*; do
    [ -e "$f" ] && ln -sfn "$f" "$FW/image/"
done
ln -sfn "$VENDOR/firmware/qca6390" "$FW/image/qca6390"
# The CS35L41 speaker/earpiece amps load their protection DSP firmware and
# calibration from the vendor's firmware folder. The driver's
# firmware_class.path points at this image folder, so link the files here.
for f in "$VENDOR"/firmware/cs35l40-*; do
    [ -e "$f" ] && ln -sfn "$f" "$FW/image/${f##*/}"
done
# pd-mapper runs as the system uid and reads the protection-domain JSON from
# this folder. The apnhlos vfat is mounted root-only (fmask=0077), so the
# symlinked .jsn files are unreadable to it and it parses zero configs; the
# audio PDR (avs/audio) is then never published to the service locator and the
# ADSP rejects every stream open. Copy the JSON as plain files and make the
# folder traversable so pd-mapper can read it.
chmod 0755 "$FW/image"
for f in "$APNHLOS"/image/*.jsn; do
    [ -e "$f" ] || continue
    rm -f "$FW/image/${f##*/}"
    cp "$f" "$FW/image/${f##*/}"
    chmod 0644 "$FW/image/${f##*/}"
done
log "symlinks done"
log "pd-mapper json: $(ls "$FW/image"/*.jsn 2>/dev/null | wc -l) files"
log "firmware: apnhlos=$(grep -c " $APNHLOS " /proc/mounts) qca6390=$(readlink "$FW/image/qca6390")"

# 3. efs and persist: macloader reads the factory MAC from efs, and the
#    phone's programs still open /persist.
mkdir -p /mnt/vendor/efs /mnt/vendor/persist
grep -q ' /mnt/vendor/efs ' /proc/mounts ||
    mount -o ro /dev/block/bootdevice/by-name/efs /mnt/vendor/efs 2>>"$LOG"
grep -q ' /mnt/vendor/persist ' /proc/mounts ||
    mount -o ro /dev/block/bootdevice/by-name/persist /mnt/vendor/persist 2>>"$LOG"
ln -sfn /mnt/vendor/efs /efs
ln -sfn /mnt/vendor/persist /persist
log "efs/persist mounted"

# 4. The configs the host driver and the supplicant read. Keep them in the
#    recovery's own /vendor, which is writable and never unmounted.
mkdir -p /vendor/etc/wifi /etc/firmware/wlan /tmp/recovery
cp -f "$VENDOR/etc/wifi/WCNSS_qcom_cfg.ini" /vendor/etc/wifi/ 2>>"$LOG"
cp -f "$VENDOR/etc/wifi/WCNSS_qcom_cfg.ini" /etc/firmware/wlan/ 2>>"$LOG"
# The AERA supplicant drops to the wifi uid, so it must be able to walk to
# the config and read it. The vendor config carries options this build does
# not use; a minimal one with sae_pwe=2 (WPA3/SAE, as the stock config has)
# is what the recovery needs.
chmod 0755 /vendor/etc /vendor/etc/wifi
cat > /vendor/etc/wifi/wpa_supplicant.conf <<EOF
ctrl_interface=/tmp/recovery/sockets
update_config=1
sae_pwe=2
pmf=1
EOF
cp -f /vendor/etc/wifi/wpa_supplicant.conf /tmp/recovery/ 2>>"$LOG"
chmod 0644 /vendor/etc/wifi/WCNSS_qcom_cfg.ini /vendor/etc/wifi/wpa_supplicant.conf

# The host driver asks the firmware loader for wlan/qca_cld/WCNSS_qcom_cfg.ini
# (not wlan/WCNSS_qcom_cfg.ini). Put it where the loader looks.
mkdir -p "$FW/image/wlan/qca_cld" /vendor/firmware/wlan/qca_cld
cp -f /vendor/etc/wifi/WCNSS_qcom_cfg.ini /vendor/firmware/wlan/qca_cld/ 2>>"$LOG"
ln -sfn /vendor/etc/wifi/WCNSS_qcom_cfg.ini "$FW/image/wlan/qca_cld/WCNSS_qcom_cfg.ini"
[ -e /vendor/firmware/wlan/qca_cld/wlan_mac.bin ] &&
    ln -sfn /vendor/firmware/wlan/qca_cld/wlan_mac.bin "$FW/image/wlan/qca_cld/wlan_mac.bin"
# -C is only used when -c is absent; the control interface belongs in the
# config file.
grep -q '^ctrl_interface=' /tmp/recovery/wpa_supplicant.conf ||
    echo 'ctrl_interface=/tmp/recovery/sockets' >> /tmp/recovery/wpa_supplicant.conf
log "configs written"

# 5. The vendor's libc++ is the one the vendor's programs were built against.
mkdir -p "$LIBKT"
cp -f "$VENDOR/lib64/libc++.so" "$LIBKT/libc++.so" 2>>"$LOG"
chmod 755 "$LIBKT"
chmod 644 "$LIBKT/libc++.so"
log "libkt ready"

# 6. The IPA node: the phone's own init writes it at early-boot, and the WLAN
#    host driver refuses to probe if the IPA's SMMU view is not set.
[ -e /dev/ipa ] && echo 1 > /dev/ipa 2>>"$LOG"
log "ipa ready"

# 7. cnss-daemon needs its socket directory before it can bind
#    cnss_user_server, but it must never touch real /data: files created here
#    carry recovery's SELinux label, and Android's cnss-daemon is then denied
#    unlinking the stale socket ("Address already in use"), which leaves Wi-Fi
#    dead until /data is wiped. Put a tmpfs over the directory so the sockets
#    vanish with this boot.
#    Heal entries left behind by older builds: Android recreates both
#    directories with the right label and ownership on its next boot. Runs
#    before the tmpfs, which would otherwise hide them.
if ! grep -q ' /data ' /proc/mounts; then
    log "data is not mounted"
    exit 1
fi
rm -rf /data/vendor/wifi/sockets /data/vendor/wifi/wpa 2>/dev/null
mkdir -p /data/vendor/wifi
grep -q ' /data/vendor/wifi tmpfs ' /proc/mounts ||
    mount -t tmpfs tmpfs /data/vendor/wifi 2>>"$LOG"
if ! grep -q ' /data/vendor/wifi tmpfs ' /proc/mounts; then
    log "cannot mount tmpfs over /data/vendor/wifi"
    exit 1
fi
mkdir -p /data/vendor/wifi/sockets /data/vendor/wifi/wpa/sockets
chown -R system:system /data/vendor/wifi
chmod 0770 /data/vendor/wifi/sockets
chmod 0777 /data/vendor/wifi/wpa/sockets
# Leave /data/vendor/conn alone: it belongs to Android's Wi-Fi stack and
# recovery has no writer for it. Recursively chowning it to system can break
# the wifi uid's access.
log "wifi dirs ready"

# The MAC node belongs to wifi, as the phone's own init gives it.
[ -e /sys/wifi/mac_addr ] && chown wifi:wifi /sys/wifi/mac_addr && chmod 0660 /sys/wifi/mac_addr

# 8. The name service and the chip's board-data daemon.
setprop ctl.start qrtr-ns
setprop ctl.start cnss-daemon
i=0
while [ ! -e /data/vendor/wifi/sockets/cnss_user_server ] && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
done
if [ ! -e /data/vendor/wifi/sockets/cnss_user_server ]; then
    log "cnss-daemon did not open its socket"
else
    log "cnss-daemon ready after $((i * 100))ms"
fi

# 9. Tell the kernel the filesystem is ready: this starts cold-boot
#    calibration, which the driver load below waits for.
echo 1 > /sys/kernel/cnss/fs_ready 2>>"$LOG"
log "fs_ready written"

# 10. The MAC loader.
setprop ctl.start macloader

# 11. The supplicant wrapper waits for wlan0 and keeps the init service
#     "running" while the driver loads the firmware.
setprop ctl.start wpa_supplicant

# 12. Ask the resident host driver to load. The write does not return until
#     the chip's firmware has booted, so it runs in the background.
if [ -e /dev/wlan ]; then
    ( echo ON > /dev/wlan ) >/dev/null 2>&1 &
fi
log "driver load requested"

# 13. Wait for the interface.
i=0
while [ ! -e /sys/class/net/wlan0 ] && [ "$i" -lt 200 ]; do
    sleep 0.1
    i=$((i + 1))
done

if [ ! -e /sys/class/net/wlan0 ]; then
    log "wlan0 did not appear"
    exit 1
fi
log "wlan0 appeared after $((i * 100))ms"

ifconfig wlan0 up 2>>"$LOG"
log "wlan0 up, mac=$(cat /sys/class/net/wlan0/address 2>/dev/null)"

# 14. The ADSP loads its AVS shared libraries (the audio_pd modules: decoders,
#     fluence, ASM/ADM/AFE) from the dsp partition, which the phone's fstab
#     mounts at /vendor/dsp. Recovery never mounts it, so the ADSP comes up
#     without the ASM service and every PCM stream open fails with
#     ADSP_EFAILED. Mount it before boot-adsp so the modules are present when
#     the ADSP is brought out of reset.
mkdir -p /vendor/dsp
grep -q ' /vendor/dsp ' /proc/mounts ||
    mount -o ro,nosuid,nodev,barrier=1 /dev/block/bootdevice/by-name/dsp \
        /vendor/dsp 2>>"$LOG"
log "dsp mounted: $(ls /vendor/dsp/adsp 2>/dev/null | wc -l) adsp modules"

# 15. The audio PDR (avs/audio) is mapped by the Qualcomm protection-domain
#     services. The phone's own init starts them from init.recovery.modem.rc,
#     which recovery does not import. Start them after the WLAN bring-up so
#     their QMI/QRTR use cannot race the cnss-daemon, then boot the ADSP once
#     the PDR services are up.
setprop ctl.start pd-mapper
setprop ctl.start pm-service
setprop ctl.start boot-adsp
log "audio services started"

# 16. The supplicant drops to the wifi uid; its control folder must be
#     reachable and owned by that user.
mkdir -p /tmp/recovery/sockets
chmod 0755 /tmp/recovery
chown wifi:wifi /tmp/recovery/sockets
chmod 0777 /tmp/recovery/sockets
log "done"
