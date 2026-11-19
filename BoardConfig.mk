#
# Copyright (C) 2024-2026 The Android Open Source Project
# Copyright (C) 2022 The TWRP Open Source Project
#
# SPDX-License-Identifier: Apache-2.0
#

DEVICE_PATH := device/samsung/r8q

ALLOW_MISSING_DEPENDENCIES := true

# Platform / SoC (SM8250, kona family)
TARGET_BOARD_PLATFORM := kona
TARGET_BOARD_PLATFORM_GPU := qcom-adreno650
QCOM_BOARD_PLATFORMS += kona

# Architecture
TARGET_ARCH := arm64
TARGET_ARCH_VARIANT := armv8-a
TARGET_CPU_ABI := arm64-v8a
TARGET_CPU_ABI2 :=
TARGET_CPU_VARIANT := generic
TARGET_CPU_VARIANT_RUNTIME := kryo300

TARGET_2ND_ARCH := arm
TARGET_2ND_ARCH_VARIANT := armv8-2a
TARGET_2ND_CPU_ABI := armeabi-v7a
TARGET_2ND_CPU_ABI2 := armeabi
TARGET_2ND_CPU_VARIANT := $(TARGET_CPU_VARIANT)
TARGET_2ND_CPU_VARIANT_RUNTIME := cortex-a75

# Bootloader
BOARD_VENDOR := samsung
TARGET_BOOTLOADER_BOARD_NAME := kona
TARGET_NO_BOOTLOADER := true
TARGET_NO_RADIOIMAGE := true
TARGET_OTA_ASSERT_DEVICE := r8q

# Kernel
# r8q ships a monolithic kernel: recovery is a normal boot-header-v2 image with
# the kernel, the gzip ramdisk, the recovery dtbo and the dtb in one file.
TARGET_KERNEL_ARCH := $(TARGET_ARCH)
BOARD_KERNEL_IMAGE_NAME := Image.gz
TARGET_PREBUILT_KERNEL := $(DEVICE_PATH)/prebuilt/$(BOARD_KERNEL_IMAGE_NAME)
BOARD_INCLUDE_RECOVERY_DTBO := true
BOARD_PREBUILT_DTBOIMAGE := $(DEVICE_PATH)/prebuilt/dtbo.img

BOARD_KERNEL_CMDLINE := \
    console=null \
    androidboot.hardware=qcom \
    androidboot.memcg=1 \
    lpm_levels.sleep_disabled=1 \
    video=vfb:640x400,bpp=32,memsize=3072000 \
    msm_rtb.filter=0x237 \
    service_locator.enable=1 \
    androidboot.usbcontroller=a600000.dwc3 \
    swiotlb=2048 \
    printk.devkmsg=on \
    firmware_class.path=/vendor/firmware_mnt/image \
    loop.max_part=7

BOARD_KERNEL_BASE := 0x00000000
BOARD_KERNEL_PAGESIZE := 4096
BOARD_BOOT_HEADER_VERSION := 2
# Samsung's bootloader expects SEANDROIDENFORCE at the end of the image. The
# custom rule appends it before the AVB footer, so the finished image is
# exactly BOARD_RECOVERYIMAGE_PARTITION_SIZE instead of 16 bytes larger.
BOARD_CUSTOM_BOOTIMG_MK := $(DEVICE_PATH)/mkbootimg.mk
BOARD_MKBOOTIMG_ARGS := \
    --dtb $(DEVICE_PATH)/prebuilt/dtb \
    --kernel_offset 0x00008000 \
    --ramdisk_offset 0x02000000 \
    --tags_offset 0x01e00000 \
    --dtb_offset 0x01f00000 \
    --header_version $(BOARD_BOOT_HEADER_VERSION)
# build-recoveryimage-target reads BOARD_RECOVERY_MKBOOTIMG_ARGS; keep the
# header version there too so the bootloader gets a v2 image.
BOARD_RECOVERY_MKBOOTIMG_ARGS += \
    --dtb $(DEVICE_PATH)/prebuilt/dtb \
    --kernel_offset 0x00008000 \
    --ramdisk_offset 0x02000000 \
    --tags_offset 0x01e00000 \
    --dtb_offset 0x01f00000 \
    --header_version $(BOARD_BOOT_HEADER_VERSION)

BOARD_ROOT_EXTRA_FOLDERS := \
    carrier \
    efs \
    keydata \
    keyrefuge \
    metadata \
    misc \
    omr \
    optics \
    prism \
    spu

# Android Verified Boot (unlocked bootloader; testkey is fine)
BOARD_AVB_ENABLE := true
BOARD_AVB_RECOVERY_KEY_PATH := external/avb/test/data/testkey_rsa4096.pem
BOARD_AVB_RECOVERY_ALGORITHM := SHA256_RSA4096
BOARD_AVB_RECOVERY_ROLLBACK_INDEX := 1
BOARD_AVB_RECOVERY_ROLLBACK_INDEX_LOCATION := 1

# Properties
TARGET_VENDOR_PROP += $(DEVICE_PATH)/vendor.prop

# r8q is a single-slot device: no A/B slots, no virtual A/B. AOSP 16 defaults
# AB_OTA_UPDATER to true when it is unset, which makes ro.build.ab_update=true
# and sends TWRP/prepdecrypt down the slot-suffixed path.
AB_OTA_UPDATER := false

# Partitions
BOARD_FLASH_BLOCK_SIZE := 262144 # (BOARD_KERNEL_PAGESIZE * 64)
BOARD_BOOTIMAGE_PARTITION_SIZE := 82694144
BOARD_DTBOIMG_PARTITION_SIZE := 25165824
BOARD_RECOVERYIMAGE_PARTITION_SIZE := 82694144

# Compress the recovery ramdisk with LZMA. The vanadium kernel has
# CONFIG_RD_LZMA, and the kernel is larger than the old one, so a gzip ramdisk
# overflows the 82,694,144 B recovery partition. LZMA is ~19 MiB smaller.
BOARD_RAMDISK_USE_LZMA := true

TARGET_USERIMAGES_USE_EXT4 := true
TARGET_USERIMAGES_USE_F2FS := true

# Dynamic partitions
BOARD_SUPER_PARTITION_SIZE := 10292822016
BOARD_SUPER_PARTITION_GROUPS := qti_dynamic_partitions
BOARD_QTI_DYNAMIC_PARTITIONS_SIZE := 10288627712
BOARD_QTI_DYNAMIC_PARTITIONS_PARTITION_LIST := system system_ext odm product vendor

BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_ODMIMAGE_FILE_SYSTEM_TYPE := ext4
TARGET_COPY_OUT_ODM := odm
BOARD_PRODUCTIMAGE_FILE_SYSTEM_TYPE := ext4
TARGET_COPY_OUT_PRODUCT := product
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := ext4
TARGET_COPY_OUT_VENDOR := vendor

# Decryption (FBE). r8q is Samsung/Qualcomm with HIDL Keymaster 4.0 and the QTI
# gatekeeper HAL; the standard qcom_decrypt/qcom_decrypt_fbe path from
# device/qcom/twrp-common starts qseecomd, keymaster and gatekeeper from the
# binaries shipped in recovery/root (see recovery/root/init.recovery.qcom.rc).
BOARD_USES_QCOM_FBE_DECRYPTION := true
BOARD_USES_METADATA_PARTITION := true
AERA_INCLUDE_CRYPTO := true
AERA_INCLUDE_CRYPTO_FBE := true
AERA_INCLUDE_FBE_METADATA_DECRYPT := true
AERA_DEFAULT_KEYMASTER_VERSION := 4.0

# Recovery
TARGET_RECOVERY_PIXEL_FORMAT := RGBX_8888
TARGET_RECOVERY_FSTAB := $(DEVICE_PATH)/recovery.fstab
TARGET_RECOVERY_QCOM_RTC_FIX := true
RECOVERY_SDCARD_ON_DATA := true
BOARD_HAS_NO_SELECT_BUTTON := true

# Use mke2fs to create ext4 images
TARGET_USES_MKE2FS := true

# The recovery ramdisk needs libion/libdmabufheap for the display and crypto
# consumers; the reference tree pulls them from the platform.
TARGET_RECOVERY_DEVICE_MODULES += \
    libion \
    libdmabufheap
RECOVERY_LIBRARY_SOURCE_FILES += \
    $(TARGET_OUT_SHARED_LIBRARIES)/libion.so \
    $(TARGET_OUT_SHARED_LIBRARIES)/libdmabufheap.so

# The qcom_decrypt package installs its own prepdecrypt.sh (0644) before the
# device-tree overlay replaces the contents, and cp keeps the old mode. Make
# the AERA wrapper executable in the packed ramdisk as well.
BOARD_RECOVERY_IMAGE_PREPARE += \
    rm -f $(TARGET_RECOVERY_ROOT_OUT)/system/etc/vintf/manifest/android.system.keystore2-service.xml; \
    chmod 0755 $(TARGET_RECOVERY_ROOT_OUT)/system/bin/prepdecrypt.sh \
        $(TARGET_RECOVERY_ROOT_OUT)/system/bin/aera-format-pending.sh

# Android crypto / AVB placeholders. prepdecrypt.sh replaces the OS and patch
# levels with the installed ROM's values before Keymaster starts.
PLATFORM_SECURITY_PATCH := 2099-12-31
VENDOR_SECURITY_PATCH := 2099-12-31
PLATFORM_VERSION := 16.1.0

# WLAN in recovery (AERA network UI + wpa_supplicant). The QCA6390 driver is
# built into the kernel; the vendor partition provides the firmware, the
# daemons and the configs. The AERA build supplies the recovery's own
# wpa_supplicant/wpa_cli/dhcptool and their libraries.
AERA_ENABLE_WLAN := 1

# AERA
AERA_THEME := portrait_hdpi
AERA_DEVICE_VERSION := Galaxy S20 FE 5G
AERA_SCREEN_BLANK_ON_BOOT := true
AERA_INPUT_BLACKLIST := "hbtp_vm"
AERA_USE_TOOLBOX := true
AERA_EXCLUDE_APEX := true
AERA_NO_LEGACY_PROPS := true
AERA_NO_BIND_SYSTEM := true
AERA_INCLUDE_REPACKTOOLS := true
AERA_INCLUDE_LOGCAT := true
AERA_EXTRA_LANGUAGES := true
TARGET_USES_LOGD := true

# Early settings caches must live on a filesystem readable before CE storage is
# unlocked. /data/recovery is device-encrypted storage: available as soon as
# metadata decryption mounts /data.
AERA_SETTINGS_ROOT_DIRECTORY := /data/recovery
AERA_MISCELLANEOUS_ROOT_DIRECTORY := /sdcard

# r8q is A-only and has a dedicated recovery partition.
AERA_AB_DEVICE_WITH_RECOVERY_PARTITION := 0

# UI geometry (1080x2400). Adaptive scaling keeps the AERA UI usable on the
# 20:9 panel; the status-bar metrics keep AERA's defaults.
AERA_SCREEN_H := 2400
AERA_UI_ADAPTIVE_RESOLUTION := true

# Brightness (panel0-backlight)
AERA_MAX_BRIGHTNESS := 486
AERA_DEFAULT_BRIGHTNESS := 128
AERA_BRIGHTNESS_PATH := "/sys/class/backlight/panel0-backlight/brightness"
AERA_CUSTOM_CPU_TEMP_PATH := "/sys/class/thermal/thermal_zone17/temp"

# Samsung download mode (Odin) and no bootloader reboot entry.
AERA_HAS_DOWNLOAD_MODE := 1
TW_NO_REBOOT_BOOTLOADER := true

# TWRP/AERA display offsets used by the portrait theme.
TW_Y_OFFSET := 89
TW_H_OFFSET := -89

# Recovery has no health HAL in this ramdisk; use the sysfs battery path.
AERA_USE_LEGACY_BATTERY_SERVICES := 1
TW_USE_LEGACY_BATTERY_SERVICES := true

# r8q uses the standard TWRP QCOM USB gadget rc shipped in recovery/root.
AERA_EXCLUDE_DEFAULT_USB_INIT := true

# NTF/exFAT tools and partition tools.
AERA_NO_EXFAT_FUSE := true
AERA_INCLUDE_NTFS_3G := true
AERA_INCLUDE_LPDUMP := true
AERA_INCLUDE_LPTOOLS := true
AERA_FRAMERATE := 120
AERA_BACKUP_EXCLUSIONS := /data/fonts
AERA_INCLUDE_LIBRESETPROP := true
AERA_INCLUDE_RESETPROP := true
AERA_ENABLE_ALL_PARTITION_TOOLS := 1
AERA_WIPE_METADATA_AFTER_DATAFORMAT := 1
