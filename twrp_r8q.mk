#
# Copyright (C) 2024-2026 The Android Open Source Project
# Copyright (C) 2022 The TWRP Open Source Project
#
# SPDX-License-Identifier: Apache-2.0
#

# AOSP base
$(call inherit-product, $(SRC_TARGET_DIR)/product/base.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit_only.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base_telephony.mk)

# Recovery common
$(call inherit-product, vendor/twrp/config/common.mk)

# Device
$(call inherit-product, device/samsung/r8q/device.mk)

PRODUCT_PLATFORM := kona

PRODUCT_RELEASE_NAME := r8q
PRODUCT_DEVICE := r8q
PRODUCT_NAME := twrp_r8q
PRODUCT_BRAND := samsung
PRODUCT_MODEL := SM-G781B
PRODUCT_MANUFACTURER := samsung
PRODUCT_GMS_CLIENTID_BASE := android-samsung

# Recovery-only builds ship no usable kernel image metadata.
PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS := false

PRODUCT_BUILD_PROP_OVERRIDES += \
    PRIVATE_BUILD_DESC="r8qxx-user 13 TP1A.220624.014 G781BXXU4DWA2 release-keys"

BUILD_FINGERPRINT := samsung/r8qxx/r8q:13/TP1A.220624.014/G781BXXU4DWA2:user/release-keys
