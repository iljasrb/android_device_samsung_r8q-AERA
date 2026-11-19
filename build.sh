#!/usr/bin/env bash
# Build AERA recovery for the Samsung Galaxy S20 FE 5G (r8q).
#
#   AERA_DIR=~/aera_16.0 ./build.sh [options]
#
# Installs this tree into $AERA_DIR/device/samsung/r8q, applies the patches in
# patches/, and builds recoveryimage.
set -eo pipefail
# not -u: AOSP's envsetup.sh/lunch reference unbound variables (TOP).

readonly root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly aera_dir="${AERA_DIR:?set AERA_DIR to a synced aera_16.0 checkout}"
readonly dest_tree="$aera_dir/device/samsung/r8q"

jobs="$(nproc)"
clean=false
enable_ccache=false
patches_only=false
sync_checkout=false

usage() {
    cat <<EOF
Usage: AERA_DIR=... $0 [options]

Options:
  -j, --jobs N       Build with N jobs (default: $(nproc))
      --clean        Remove the AERA out/ tree before building
      --ccache       Enable ccache when it is installed
      --patches-only Install the device tree and apply patches, then stop
      --sync         Update the AERA checkout with repo sync first
  -h, --help         Show this help
EOF
}

while (($#)); do
    case "$1" in
        -j|--jobs)
            jobs="${2:?--jobs needs a value}"
            shift 2
            ;;
        -j[0-9]*)
            jobs="${1#-j}"
            shift
            ;;
        --jobs=*)
            jobs="${1#--jobs=}"
            shift
            ;;
        --clean)
            clean=true
            shift
            ;;
        --ccache)
            enable_ccache=true
            shift
            ;;
        --patches-only)
            patches_only=true
            shift
            ;;
        --sync)
            sync_checkout=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || {
    printf 'Invalid job count: %s\n' "$jobs" >&2
    exit 2
}

[[ -f "$aera_dir/build/envsetup.sh" ]] || {
    printf 'AERA_DIR (%s) is not a synced aera_16.0 checkout\n' "$aera_dir" >&2
    exit 1
}

# Keep grep/sort/awk deterministic and slightly faster on non-English hosts.
export LC_ALL=C

if $sync_checkout; then
    if command -v repo >/dev/null 2>&1; then
        printf 'Syncing AERA checkout at %s ...\n' "$aera_dir"
        (cd "$aera_dir" && repo sync -d -j"$jobs")
    else
        printf 'repo is not installed; update %s manually or install repo.\n' \
            "$aera_dir" >&2
        exit 1
    fi
fi

if $clean; then
    printf 'Removing %s/out ...\n' "$aera_dir"
    rm -rf "$aera_dir/out"
fi

if $enable_ccache; then
    if command -v ccache >/dev/null 2>&1; then
        export USE_CCACHE=1
        export CCACHE_EXEC="$(command -v ccache)"
        export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
        printf 'ccache enabled: %s (%s)\n' "$CCACHE_EXEC" "$CCACHE_DIR"
    else
        printf 'ccache requested but not installed; continuing without it.\n' >&2
    fi
fi

tree_files=(
    Android.bp
    Android.mk
    AndroidProducts.mk
    BoardConfig.mk
    device.mk
    aera_r8q.mk
    twrp_r8q.mk
    mkbootimg.mk
    recovery.fstab
    vendor.prop
    system.prop
    vendorsetup.sh
    recovery
    prebuilt
    gpu
    input
)

# rsync preserves unchanged timestamps, so an incremental build only notices the
# files that actually changed. The rm -rf + cp -a path is the portable fallback.
install_tree() {
    local entry name keep
    if command -v rsync >/dev/null 2>&1; then
        mkdir -p "$dest_tree"
        # Drop top-level entries that are no longer part of the tree.
        for entry in "$dest_tree"/* "$dest_tree"/.[!.]*; do
            [[ -e "$entry" ]] || continue
            keep=false
            for name in "${tree_files[@]}"; do
                if [[ "$(basename "$entry")" == "$name" ]]; then
                    keep=true
                    break
                fi
            done
            $keep || rm -rf "$entry"
        done
        for name in "${tree_files[@]}"; do
            if [[ -d "$root_dir/$name" ]]; then
                # busybox is installed below, not part of the source tree; keep
                # it across incremental installs so its timestamp stays stable.
                rsync -a --delete --exclude=root/system/bin/busybox \
                    "$root_dir/$name/" "$dest_tree/$name/"
            else
                rsync -a "$root_dir/$name" "$dest_tree/"
            fi
        done
    else
        rm -rf "$dest_tree"
        mkdir -p "$dest_tree"
        cp -a "${tree_files[@]/#/$root_dir/}" "$dest_tree"/
    fi
}

# Apply a patch once. The marker check covers patches that are already applied
# and whose context has since been moved by a later patch in the same file.
patch_repo() {
    local repo="$1"
    local patch="$2"
    local marker_file="$3"
    local marker="$4"
    local name
    name="$(basename "$patch")"

    if [[ -n "$marker_file" ]] &&
        grep -qF -- "$marker" "$repo/$marker_file" 2>/dev/null; then
        printf '  %-48s already applied\n' "$name"
        return 0
    fi
    if git -C "$repo" apply --reverse --check "$patch" >/dev/null 2>&1; then
        printf '  %-48s already applied\n' "$name"
        return 0
    fi
    if ! git -C "$repo" apply --check "$patch" >/dev/null 2>&1; then
        printf 'ERROR: %s no longer applies to %s\n' "$name" "$repo" >&2
        git -C "$repo" apply --check "$patch" >&2 || true
        exit 1
    fi
    git -C "$repo" apply "$patch"
    printf '  %-48s applied\n' "$name"
}

install_tree
printf 'Installed device tree at %s\n' "$dest_tree"

# The microSD tray's detect line: the vendor tree calls it active high and
# leaves it without a pull, while the board pulls the line up and grounds it
# as a card goes in. Patch the recovery's own copies, leaving the installed
# system's alone. Idempotent.
if command -v python3 >/dev/null 2>&1; then
    python3 "$root_dir/scripts/fix-sdcard-dtb.py" \
        "$dest_tree/prebuilt/dtb" "$dest_tree/prebuilt/dtbo.img"
else
    printf 'python3 not found; microSD detect-line fix not applied\n' >&2
fi

# The MDFPP gatekeeper module takes its HIDL instance name from HMI.name, which
# the stock blob sets to "MDFPP Gatekeeper"; recovery looks up
# IGatekeeper/default. Rewrite the pointer to the module's "gatekeeper" string.
# Idempotent, so a refreshed vendor blob is patched on the next install.
if command -v python3 >/dev/null 2>&1; then
    python3 "$root_dir/scripts/patch-gatekeeper-name.py" \
        "$dest_tree/recovery/root/vendor/lib64/hw/gatekeeper.mdfpp.so"
else
    printf 'python3 not found; gatekeeper HMI.name patch not applied\n' >&2
fi

# AERA's plugin store, updater and font downloader call `busybox wget`; the AERA
# ramdisk script drops /sbin/busybox, so install the vendored static busybox at
# the documented fallback path.
busybox="$aera_dir/vendor/recovery/prebuilt/arm64/busybox"
[[ -f "$busybox" ]] || {
    printf 'Missing vendored busybox: %s\n' "$busybox" >&2
    exit 1
}
busybox_dest="$dest_tree/recovery/root/system/bin/busybox"
if ! cmp -s "$busybox" "$busybox_dest"; then
    install -D -m 0755 "$busybox" "$busybox_dest"
fi

# The patched repositories must exist before git apply runs.
for repo in system/security/keystore2 system/libhidl system/core \
    bootable/recovery vendor/recovery; do
    git -C "$aera_dir/$repo" rev-parse --git-dir >/dev/null 2>&1 || {
        printf 'Missing git repository: %s\n' "$aera_dir/$repo" >&2
        exit 1
    }
done

ks2="$aera_dir/system/security/keystore2"
hidl="$aera_dir/system/libhidl"
core="$aera_dir/system/core"
recovery_mod="$aera_dir/bootable/recovery"
vendor_recovery="$aera_dir/vendor/recovery"

# Recovery resolves HIDL to passthrough; ENFORCE_VINTF_MANIFEST rejects the
# gatekeeper registration and the vendor HAL is unreachable.
#
# SECURITY: this disables a VINTF manifest check in libhidl. It is required for
# gatekeeper passthrough in recovery; never widen it beyond libhidl's default
# cflags block.
patch_repo "$hidl" \
    "$root_dir/patches/generic/libhidl-recovery-passthrough-no-vintf-enforce.patch" \
    Android.bp 'libhidl still resolves'

# fastbootd resolves health/fastboot HALs while USB is still closed; recovery has
# neither, so the blocking waits hang the daemon and USB never re-enumerates.
patch_repo "$core" "$root_dir/patches/generic/fastbootd-hal-nonblocking.patch" \
    fastboot/device/fastboot_device.cpp 'Never wait here: fastbootd is'

# The sys.usb.config=none trigger only removed f1. MTP creates f1..f4, so a
# leftover function link could make the next gadget bind fail with -ENODEV.
# Clear every function link before the next configuration.
patch_repo "$recovery_mod" \
    "$root_dir/patches/generic/recovery-usb-none-clear-functions.patch" \
    etc/init.rc 'rm /config/usb_gadget/g1/configs/b.1/f9'

# The Adreno path imported gralloc/native-buffer scanouts, but recovery has no
# vendor graphics stack before decryption. Composite into a pbuffer and read the
# frame back into minui's DRM scanout buffer instead.
patch_repo "$recovery_mod" "$root_dir/patches/generic/aeraui-gpu-readback-scanout.patch" \
    aeraui/core/gpu_renderer.cpp 'software-scanout GPU ready'

# The global LD_PRELOAD shim is needed for the mapper HAL, but it must not leak
# into installer/plugin `sh` children: they run with the ROM's /system mounted,
# where the recovery shim does not exist. Clear it in the renderer once the
# shim is loaded into the process.
patch_repo "$recovery_mod" \
    "$root_dir/patches/generic/aeraui-gpu-unset-preload.patch" \
    aeraui/core/gpu_renderer.cpp \
    'unsetenv("LD_PRELOAD")'

# The installer stops the WLAN stack to release /vendor. Re-run the WLAN
# enable/scan/saved-connect path from the install-completion path, not a timer,
# so the radio is usable again when the install returns.
patch_repo "$recovery_mod" \
    "$root_dir/patches/generic/aeraui-wlan-restart-after-install.patch" \
    aeraui/platform/aera_backend.cpp \
    'RestartWlanAfterInstall'

# The decrypt page is shown before backend_ready_; the pointer gate must not
# swallow its touches.
patch_repo "$recovery_mod" "$root_dir/patches/generic/aeraui-decrypt-touch.patch" \
    aeraui/core/engine.cpp 'The decrypt page runs before backend_ready_'

# Prefer the bootloader's factory wifimacaddr= over the serial-derived MAC.
patch_repo "$recovery_mod" "$root_dir/patches/generic/recovery-wlan-factory-mac.patch" \
    wlan.cpp 'wifimacaddr='

# TestConnection used `busybox ping`, absent here; probe with native sockets.
patch_repo "$recovery_mod" \
    "$root_dir/patches/generic/recovery-wlan-native-connectivity-test.patch" \
    wlan.cpp 'static bool ProbeTcp'

# The Wi-Fi switch consumed the tap, so only the label toggled the radio.
patch_repo "$recovery_mod" "$root_dir/patches/generic/aeraui-wifi-toggle-click.patch" \
    aeraui/scenes/wifi_scene.cpp 'The switch is only an indicator'

# The browser jail requires a cgroup v1 memory controller. r8q's kernel exposes
# no memory controller at all (only cpuset/cpu/cpuacct/schedtune/blkio/freezer),
# so the jail died with "browser resource limits" and the browser never started.
# Keep the task-group tree kill and run without a hard memory bound instead.
patch_repo "$recovery_mod" \
    "$root_dir/patches/experimental/aeraui-browser-cgroup-v2-memory.patch" \
    aeraui/features/browser/jail_main.cpp \
    'memory cgroup unavailable; no hard memory limit'

# A recovery kernel built without CONFIG_SECCOMP rejects every filter with
# EINVAL, which made the browser/Telegram jail exit before exec. Keep the
# chroot/UID/capability isolation and skip only the syscall filter.
patch_repo "$recovery_mod" \
    "$root_dir/patches/experimental/aeraui-browser-seccomp-optional.patch" \
    aeraui/features/browser/jail_main.cpp 'SeccompAvailable'

# One recovery-owned GStreamer plugin set shared by every app jail, with a
# forced registry update so newly added plugins (scaletempo, Ogg/Vorbis) are
# visible without depending on the per-app plugin payloads.
patch_repo "$recovery_mod" \
    "$root_dir/patches/experimental/aeraui-browser-global-gst-plugins.patch" \
    aeraui/features/browser/jail_main.cpp 'aera-gst-plugins'

# The browser runtime payload that the plugin store ships carries an old copy
# of the recovery audio sink at /usr/lib/gstreamer-1.0/libgstaeraaudio.so. It
# loads from GST_PLUGIN_SYSTEM_PATH and shadows ours, so bind our file over it.
# The downloadable payload itself stays untouched.
patch_repo "$recovery_mod" \
    "$root_dir/patches/experimental/aeraui-browser-gst-sink-override.patch" \
    aeraui/features/browser/jail_main.cpp 'global GStreamer audio sink'

# WebKit stages media in /var/tmp, which the extracted browser runtime does not
# have at all, so progressive playback failed with "Could not create temp file"
# and an MSE seek had nowhere to buffer.
patch_repo "$recovery_mod" \
    "$root_dir/patches/experimental/aeraui-browser-media-var-tmp.patch" \
    aeraui/features/browser/jail_main.cpp 'private media temporary storage'

# Build tinyalsa's tinyplay/tinymix into the recovery so the ASoC PCM path can
# be tested on-device without the vendor audio HAL.
patch_repo "$aera_dir/external/tinyalsa" \
    "$root_dir/patches/plugins/tinyalsa-recovery-tools.patch" \
    Android.bp 'recovery_available: true'
patch_repo "$recovery_mod" \
    "$root_dir/patches/plugins/aeraui-recovery-tinyalsa-tools.patch" \
    aeraui/Android.bp 'tinyplay'
patch_repo "$recovery_mod" \
    "$root_dir/patches/plugins/aeraui-audio-pcm-bridge.patch" \
    aeraui/features/audio/pcm_bridge.c \
    'PCM bridge for the isolated AERA browser'

# The address field only loaded on the virtual keyboard's ready key; pressing
# Enter in the field itself did nothing. Wire LV_EVENT_READY as well.
patch_repo "$recovery_mod" \
    "$root_dir/patches/experimental/aeraui-browser-address-enter.patch" \
    aeraui/features/browser/web_scene.cpp \
    'Enter in the address field loads it'

# The animated fastboot hand-off segfaulted inside LVGL before
# RecoveryEnterFastbootd(); use a fade, fall back to cold boot-fastboot, and use
# the sys.usb.config.aera_fastbootd marker (ro.* writes are dropped).
patch_repo "$recovery_mod" "$root_dir/patches/generic/aeraui-fastbootd-live-entry.patch" \
    aeraui/core/runner.cpp 'live fastbootd failed; rebooting to cold fastbootd'

# A CLI mode transition requested while the display is suspended never runs
# its fade animation, leaving gModeTransitionBusy set and the UI on Home.
# Wake the display before starting the transition.
patch_repo "$recovery_mod" \
    "$root_dir/patches/generic/aeraui-fastboot-transition-wake.patch" \
    aeraui/core/runner.cpp 'A CLI mode transition requested'

# The in-recovery updater must read the same catalog that scripts/publish.sh
# writes to the r8q mirror.
patch_repo "$recovery_mod" \
    "$root_dir/patches/generic/aeraui-update-catalog-mirror.patch" \
    aeraui/features/update/update_manager.cpp 'rom.flac.moe/r8q/recovery/aera/catalog.json'

# Sideload serves the package over FUSE, which has no random access; the zip
# installer aborted mid-package. Stage it in tmpfs first.
patch_repo "$recovery_mod" \
    "$root_dir/patches/generic/recovery-sideload-stage-package.patch" \
    twrpinstall/adb_install.cpp 'kLocalPackage'

# Samsung/Lineage vendor init restores /vendor/etc/recovery.img when
# persist.vendor.recovery_update is true. Third-party OTAs set that property,
# which made Lineage recovery replace AERA on the next boot. Clear it after a
# successful install so AERA survives.
patch_repo "$recovery_mod" \
    "$root_dir/patches/experimental/recovery-sideload-disable-stock-recovery.patch" \
    aera_core.cpp 'persist.vendor.recovery_update'

# Recovery pins /vendor for the boot once its libraries are mapped; the zip
# installer refuses to run until /vendor is unmounted. Release it before install.
patch_repo "$recovery_mod" \
    "$root_dir/patches/generic/recovery-release-vendor-mounts.patch" \
    aeraui/platform/aera_backend.cpp 'ReleaseVendorMountsForInstall'

# make_f2fs leaves userdata checkpoint-disabled, so every write made in a
# recovery session was rolled back on the next boot (settings, backups).
patch_repo "$recovery_mod" "$root_dir/patches/generic/recovery-userdata-checkpoint.patch" \
    partition.cpp 'checkpoint=enable'

# A blanked screen ignored touch: every evdev ABS event was dropped while
# screen_off was set, and only hardware keys cleared it.
patch_repo "$recovery_mod" "$root_dir/patches/generic/aeraui-touch-wake.patch" \
    aeraui/core/runner.cpp 'A touch is a wake gesture'

# The transition animation is UI-only; its removal is unrelated to fastbootd.
patch_repo "$recovery_mod" \
    "$root_dir/patches/generic/aeraui-power-transition-simplify.patch" \
    aeraui/components/power_transition.cpp \
    'Keep the hand-off short and deliberately simple'

# The UI autosaves during startup, before /data is necessarily mounted; without
# a load-first guard those session defaults overwrite the stored preferences.
patch_repo "$recovery_mod" \
    "$root_dir/patches/generic/aeraui-preferences-persistence.patch" \
    aeraui/platform/aera_backend.cpp 'gPreferencesLoaded'

# charger polls a health HAL that recovery does not have (1 s block per try).
patch_repo "$recovery_mod" "$root_dir/patches/generic/recovery-stop-charger.patch" \
    etc/init.rc 'Not started in recovery: charger polls'

# Fades call Set_Brightness per frame; throttle its logging.
patch_repo "$recovery_mod" \
    "$root_dir/patches/generic/recovery-brightness-log-throttle.patch" \
    twrp-functions.cpp 'last_logged'

# A hand-rolled fork()+execl() can deadlock before exec while the early UI
# threads are running; posix_spawn keeps the resetprop fallback from wedging
# boot on an empty /data.
patch_repo "$recovery_mod" \
    "$root_dir/patches/generic/recovery-exec-cmd-posix-spawn.patch" \
    twrp-functions.cpp 'posix_spawn is safe while the native UI'

# Update_Log_File() now spawns pigz through posix_spawnp for the same reason;
# the old fork() child could stall before exec and fill the log pipe.
patch_repo "$recovery_mod" \
    "$root_dir/patches/generic/recovery-log-pigz-posix-spawn.patch" \
    twrp-functions.cpp 'posix_spawnp(pigz)'

# Format Data needs the crypto consumers stopped before mkfs.f2fs.
patch_repo "$recovery_mod" \
    "$root_dir/patches/generic/recovery-format-data-unmount.patch" \
    aeraui/platform/aera_backend.cpp 'keystore2 -> /data/misc/keystore'

# Vendor data is regenerated by Android; excluding it from data backups avoids
# the fscrypt-policy restore failure after format-data.
patch_repo "$recovery_mod" \
    "$root_dir/patches/generic/recovery-data-backup-no-vendor.patch" \
    partition.cpp 'Vendor data is regenerated by Android'

# Create a minimal /data layout after an FBE Format Data so recovery can boot
# without a ROM; Android fills in the rest on first boot.
patch_repo "$recovery_mod" \
    "$root_dir/patches/generic/recovery-fbe-format-skeleton.patch" \
    partition.cpp 'Keep recovery bootable after a standalone Format Data'

# Accept bare partition names (boot) as well as paths (/boot) in the CLI.
patch_repo "$recovery_mod" \
    "$root_dir/patches/generic/recovery-cli-part-paths.patch" \
    aera_rpc/aera_engine.cpp 'PartitionPaths'

# The installer zip's debug vars dump would otherwise list the builder's
# absolute tree path.
patch_repo "$vendor_recovery" "$root_dir/patches/generic/recovery-build-vars-redact.patch" \
    AERA_A16.sh '/AERA_DIR/d'

if $patches_only; then
    printf 'Device tree installed and patches applied; stopping before the build.\n'
    exit 0
fi

cd "$aera_dir"

# Keep the build host out of ro.build.user/ro.build.host in the published image.
export BUILD_USERNAME=aera
export BUILD_HOSTNAME=aera

export AERA_BUILD_DEVICE=r8q
# shellcheck disable=SC1091
source build/envsetup.sh
lunch twrp_r8q-bp2a-eng
product_dir="$aera_dir/out/target/product/r8q"
# The recovery root is assembled incrementally; drop it so files removed from
# the device tree (e.g. stale init rc overrides) do not survive in the image.
rm -rf "$product_dir/recovery/root"
mka -j"$jobs" adbd recoveryimage

# Catch the two files whose absence has already caused wasted flashes: the
# headless input tool and the clock hook. Fail before packaging/flashing.
for required in \
    "$product_dir/recovery/root/system/bin/aera-input" \
    "$product_dir/recovery/root/system/bin/clock-sync.sh"; do
    [[ -f "$required" ]] || {
        printf 'Missing from the assembled recovery root: %s\n' "$required" >&2
        exit 1
    }
done
grep -q '^service clock-sync ' "$product_dir/recovery/root/init.recovery.qcom.rc" || {
    printf 'clock-sync service is missing from %s\n' \
        "$product_dir/recovery/root/init.recovery.qcom.rc" >&2
    exit 1
}

# The Adreno closure is split across the vendor directory and the platform
# libraries the recovery installs; resolve every DT_NEEDED entry in the
# assembled ramdisk before packaging it.
if command -v python3 >/dev/null 2>&1; then
    python3 "$root_dir/scripts/check-gpu-closure.py" "$product_dir/recovery/root"
else
    printf 'python3 not found; GPU closure not checked\n' >&2
fi

image=$(ls -t "$product_dir"/AERA-*.img 2>/dev/null | head -1)
zip=$(ls -t "$product_dir"/AERA-*.zip 2>/dev/null | head -1)
[[ -n "$image" ]] || {
    printf 'No AERA image produced in %s\n' "$product_dir" >&2
    exit 1
}

# AERA_A16.sh writes the md5 with the build path; keep the published sidecars
# relative so they remain valid after copying the artifacts elsewhere.
for artifact in "$image" "$zip"; do
    [[ -n "$artifact" && -f "$artifact" ]] || continue
    ( cd "$product_dir" && md5sum "$(basename "$artifact")" > "$(basename "$artifact").md5" )
done

printf 'Recovery image: %s\n' "$image"
[[ -n "$zip" ]] && printf 'Installer zip: %s\n' "$zip"
