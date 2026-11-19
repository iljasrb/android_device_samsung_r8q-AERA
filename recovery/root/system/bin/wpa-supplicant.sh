#!/system/bin/sh
# Wait for the WLAN interface, then hand over to the recovery's supplicant.
#
# AERA's WLAN backend waits for the init service to enter "running" before it
# waits for the control socket. The driver takes tens of seconds to load the
# chip's firmware, so this wrapper keeps the service running while wlan0 is
# still missing and execs the real supplicant as soon as it appears.
#
# AERA_ENABLE_WLAN builds the recovery's own wpa_supplicant at
# /system/bin/wpa_supplicant. The vendor's binary is only a fallback: it is
# the AIDL variant and needs the vendor libraries.

i=0
while [ ! -e /sys/class/net/wlan0 ] && [ "$i" -lt 900 ]; do
    sleep 0.1
    i=$((i + 1))
done

if [ ! -e /sys/class/net/wlan0 ]; then
    echo "wpa-supplicant: wlan0 did not appear" > /dev/kmsg 2>/dev/null
    exit 1
fi

if [ -x /system/bin/wpa_supplicant ]; then
    exec /system/bin/wpa_supplicant \
        -Dnl80211 -iwlan0 \
        -c/vendor/etc/wifi/wpa_supplicant.conf \
        -C/tmp/recovery/sockets \
        -O/tmp/recovery/sockets
fi

exec /tmp/wlan-vendor/bin/hw/wpa_supplicant \
    -Dnl80211 -iwlan0 \
    -c/vendor/etc/wifi/wpa_supplicant.conf \
    -C/tmp/recovery/sockets \
    -O/tmp/recovery/sockets
