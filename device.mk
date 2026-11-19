#
# Copyright (C) 2024-2026 The Android Open Source Project
# Copyright (C) 2022 The TWRP Open Source Project
#
# SPDX-License-Identifier: Apache-2.0
#

LOCAL_PATH := device/samsung/r8q

# Enable project quotas and casefolding for emulated storage without sdcardfs
$(call inherit-product, $(SRC_TARGET_DIR)/product/emulated_storage.mk)

# VNDK
PRODUCT_TARGET_VNDK_VERSION := 30

# API
PRODUCT_SHIPPING_API_LEVEL := 29

# Dynamic partitions
PRODUCT_USE_DYNAMIC_PARTITIONS := true

# fastbootd
PRODUCT_PACKAGES += \
    android.hardware.fastboot@1.0-impl-mock \
    fastbootd

# Qualcomm FBE decryption: qseecomd + HIDL Keymaster 4.0 + QTI gatekeeper.
# The rc files are installed by device/qcom/twrp-common and imported from
# recovery/root/init.recovery.qcom.rc.
PRODUCT_PACKAGES += \
    qcom_decrypt \
    qcom_decrypt_fbe

# Test/diagnostic tool: drives the AERA UI from adb by injecting evdev events
# (recovery has no InputManager). Used by the acceptance plan.
PRODUCT_PACKAGES += \
    aera-input

# Dependencies used by the display/crypto consumers in the recovery ramdisk.
TARGET_RECOVERY_DEVICE_MODULES += \
    libion \
    libdmabufheap

RECOVERY_LIBRARY_SOURCE_FILES += \
    $(TARGET_OUT_SHARED_LIBRARIES)/libion.so \
    $(TARGET_OUT_SHARED_LIBRARIES)/libdmabufheap.so

# Adreno 650 userspace. The vendor EGL/GLES driver and its gralloc/mapper
# closure stay in /vendor/lib64; the recovery provides the A16 platform
# libui/libnativewindow and the libc++ __hash_memory shim (gpu/).
TARGET_RECOVERY_DEVICE_MODULES += \
    libaera_gpu_compat \
    libui \
    libnativewindow \
    android.hardware.graphics.common-V6-ndk

RECOVERY_LIBRARY_SOURCE_FILES += \
    $(TARGET_OUT_SHARED_LIBRARIES)/libaera_gpu_compat.so \
    $(TARGET_OUT_SHARED_LIBRARIES)/libui.so \
    $(TARGET_OUT_SHARED_LIBRARIES)/libnativewindow.so \
    $(TARGET_OUT_SHARED_LIBRARIES)/android.hardware.graphics.common-V6-ndk.so \
    $(TARGET_OUT_SHARED_LIBRARIES)/android.hardware.common-V2-ndk.so

# Screen
TARGET_SCREEN_WIDTH := 1080
TARGET_SCREEN_HEIGHT := 2400

# AERA settings
$(call inherit-product, $(LOCAL_PATH)/aera_r8q.mk)
