#!/usr/bin/env bash
# Cross-compile the AERA recovery browser audio sink plugin.
#
# autoaudiosink for the isolated browser: a GstBin with a GstBaseSink child
# that forwards fixed 48 kHz stereo S16LE PCM to the root-owned AERA audio
# bridge over an abstract AF_UNIX socket.
#
# Requires an aarch64 Alpine sysroot (musl) that matches the recovery's
# GStreamer, e.g.:
#   apk.static --root /tmp/alpine-sysroot --arch aarch64 --usermode \
#     --no-scripts --allow-untrusted --initdb add \
#     musl-dev glib-dev gstreamer-dev gst-plugins-base-dev
set -eo pipefail
readonly here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly sysroot="${SYSROOT:-/tmp/alpine-sysroot}"
readonly out="${OUT:-$here/../../recovery/root/system/etc/aera-gst-plugins/libgstaeraaudio.so}"

# The plugin is part of the aeraui browser feature in the AERA tree. When that
# checkout is available compile it from there so the two cannot drift, and keep
# the copy in this directory as the shipped, self-contained source.
readonly source_tree="${AERA_DIR:-$here/../../aera_16.0}"
readonly source_in_tree="$source_tree/bootable/recovery/aeraui/features/browser/gst_aera_audio_sink.c"
if [[ -f "$source_in_tree" ]]; then
    readonly source="$source_in_tree"
else
    readonly source="$here/gst_aera_audio_sink.c"
fi

export PKG_CONFIG_SYSROOT_DIR="$sysroot"
export PKG_CONFIG_LIBDIR="$sysroot/usr/lib/pkgconfig:$sysroot/usr/share/pkgconfig"

clang --target=aarch64-alpine-linux-musl --sysroot="$sysroot" \
    -fuse-ld=lld -fPIC -shared -nostartfiles -nodefaultlibs -O2 \
    -Wall -Wextra -Wno-unused-parameter -Wno-unused-but-set-global \
    -o "$out" "$source" \
    $(pkg-config --cflags --libs gstreamer-audio-1.0 gstreamer-base-1.0) \
    -lc -Wl,-z,relro,-z,now
chmod 0755 "$out"
printf 'built %s\n' "$out"
