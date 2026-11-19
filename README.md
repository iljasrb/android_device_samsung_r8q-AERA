# AERA Recovery — Samsung Galaxy S20 FE 5G (r8q)

## Build

Requires a synced `aera_16.0` checkout and the usual AOSP build dependencies.

```sh
AERA_DIR=~/aera_16.0 ./build.sh -j"$(nproc)" --ccache
```

Outputs in `$AERA_DIR/out/target/product/r8q/`:

- `AERA-R1.0-Beta-Unofficial-r8q.img`
- `AERA-R1.0-Beta-Unofficial-r8q.zip`
- Odin `.tar` alongside the image

## Flash

Odin: flash the `.img.tar` in the **AP** slot.

Or from a rooted Android/recovery:

```sh
adb push AERA-R1.0-Beta-Unofficial-r8q.img /data/local/tmp/aera-r8q.img
adb shell 'dd if=/data/local/tmp/aera-r8q.img of=/dev/block/sda24 bs=1M conv=fsync'
adb reboot recovery
```

r8q is single-slot; this tree only writes the dedicated recovery partition.

## Updates

The in-recovery updater reads:

```
https://rom.flac.moe/r8q/recovery/aera/catalog.json
```

## Credits

- Trees: [AERA Recovery](https://github.com/AERA-Recovery), [this device tree](https://github.com/iljasrb/android_device_samsung_r8q-AERA), [OrangeFox r8q reference](https://gitlab.com/vanadium-oss/sm8250/samsung/r8q/downstream/device-recovery)
- Kernel: [doubledashdot/kernel_samsung_sm8250](https://github.com/doubledashdot/kernel_samsung_sm8250) (`vanadium` branch)
- Other: TWRP/OrangeFox, [TheMuppets proprietary vendor](https://github.com/TheMuppets/proprietary_vendor_samsung_r8q), the Skyward r8q device configuration, and Samsung stock firmware blobs

Vendor blobs remain the property of their respective owners and are included
only for recovery use.
