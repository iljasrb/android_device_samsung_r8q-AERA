#!/system/bin/sh
# Boot the audio DSP. The phone's own init boots it; recovery's init does not,
# so the ASoC machine driver never registers a card and /proc/asound/cards
# stays empty. The write blocks until the firmware has loaded.
if [ -e /sys/kernel/boot_adsp/boot ]; then
    echo 1 > /sys/kernel/boot_adsp/boot
fi
