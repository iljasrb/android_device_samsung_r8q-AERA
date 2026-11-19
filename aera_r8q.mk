#
# Copyright (C) 2024-2026 The Android Open Source Project
#
# SPDX-License-Identifier: Apache-2.0
#

AERA_MAINTAINER := @iljasrb

# The libc++ compatibility shim used by the Adreno renderer (gpu/) lives in
# this tree's Soong namespace.
PRODUCT_SOONG_NAMESPACES += device/samsung/r8q

# Partition tools (dynamic partitions are enabled in device.mk)
AERA_ENABLE_ALL_PARTITION_TOOLS := 1
AERA_WIPE_METADATA_AFTER_DATAFORMAT := 1
