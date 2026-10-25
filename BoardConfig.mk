#
# Copyright (C) 2026 The OrangeFox Recovery Project
#
# SPDX-License-Identifier: Apache-2.0
#
# Device: Xiaomi Mi Note 10 Lite (toco) - Snapdragon 730G (SM6150 / "sdmmagpie")
# A-only, dedicated 'recovery' partition, dynamic partitions (super), boot header v2
#

DEVICE_PATH := device/xiaomi/toco

# Architecture
TARGET_ARCH := arm64
TARGET_ARCH_VARIANT := armv8-a
TARGET_CPU_ABI := arm64-v8a
TARGET_CPU_ABI2 :=
TARGET_CPU_VARIANT := generic
TARGET_CPU_VARIANT_RUNTIME := cortex-a76

TARGET_2ND_ARCH := arm
TARGET_2ND_ARCH_VARIANT := armv8-a
TARGET_2ND_CPU_ABI := armeabi-v7a
TARGET_2ND_CPU_ABI2 := armeabi
TARGET_2ND_CPU_VARIANT := generic
TARGET_2ND_CPU_VARIANT_RUNTIME := cortex-a76

TARGET_SUPPORTS_64_BIT_APPS := true
TARGET_USES_64_BIT_BINDER := true
ENABLE_CPUSETS := true
ENABLE_SCHEDBOOST := true

# Bootloader
PRODUCT_PLATFORM := sm6150
TARGET_BOOTLOADER_BOARD_NAME := sm6150
TARGET_NO_BOOTLOADER := true
TARGET_USES_UEFI := true

# Platform
TARGET_BOARD_PLATFORM := sm6150
TARGET_BOARD_PLATFORM_GPU := qcom-adreno618
QCOM_BOARD_PLATFORMS += sm6150

# A-only device with a dedicated recovery partition
AB_OTA_UPDATER := false
TARGET_NO_RECOVERY := false
BOARD_USES_RECOVERY_AS_BOOT := false

# Kernel - prebuilt, built from PixelOS-Devices/android_kernel_xiaomi_sm6150 (branch sixteen-qpr2,
# toco_defconfig, 4.14.356). The stock MIUI 4.14.117 kernel cannot be used here: it has no
# fscrypt v2 policies, no blk-crypto inline encryption and no hardware-wrapped key support,
# all of which PixelOS (Android 16) userdata relies on. See README.md.
BOARD_KERNEL_CMDLINE := console=ttyMSM0,115200n8 earlycon=msm_geni_serial,0x880000
BOARD_KERNEL_CMDLINE += androidboot.hardware=qcom androidboot.console=ttyMSM0
BOARD_KERNEL_CMDLINE += service_locator.enable=1 lpm_levels.sleep_disabled=1 loop.max_part=7
BOARD_KERNEL_CMDLINE += androidboot.usbcontroller=a600000.dwc3
BOARD_KERNEL_CMDLINE += androidboot.dynamic_partitions=true
BOARD_KERNEL_CMDLINE += androidboot.selinux=permissive

# panic=0: do not restart after a kernel panic. The phone then shows a frozen screen instead of silently falling
# back into the installed OS, which tells a panic apart from other failures, and the panic log can be read from
# pstore after a forced restart (see docs/TROUBLESHOOTING.md). Take it out once the recovery is known to be stable.
BOARD_KERNEL_CMDLINE += panic=0

# Debug kernel (export FOX_DEBUG_KERNEL=true before 'lunch'; needs prebuilt-debug/, see kernel/debug.fragment):
# KASAN + SLUB debugging to find who corrupts kernel memory. nokaslr keeps the kernel at its link address, the
# safest way to run KASAN.
ifeq ($(FOX_DEBUG_KERNEL),true)
TOCO_KERNEL_DIR := prebuilt-debug
BOARD_KERNEL_CMDLINE += kasan_multi_shot slub_debug=FZPU nokaslr
else
TOCO_KERNEL_DIR := prebuilt
endif
BOARD_KERNEL_IMAGE_NAME := Image.gz
BOARD_KERNEL_PAGESIZE := 4096
BOARD_KERNEL_BASE          := 0x00000000
BOARD_KERNEL_TAGS_OFFSET   := 0x00000100
BOARD_KERNEL_OFFSET        := 0x00008000
BOARD_KERNEL_SECOND_OFFSET := 0x00f00000
BOARD_RAMDISK_OFFSET       := 0x01000000
BOARD_DTB_OFFSET           := 0x01f00000
BOARD_BOOT_HEADER_VERSION := 2
TARGET_KERNEL_ARCH := arm64
TARGET_PREBUILT_KERNEL := $(DEVICE_PATH)/$(TOCO_KERNEL_DIR)/Image.gz
TARGET_PREBUILT_DTB := $(DEVICE_PATH)/$(TOCO_KERNEL_DIR)/dtb
BOARD_PREBUILT_DTBOIMAGE := $(DEVICE_PATH)/$(TOCO_KERNEL_DIR)/dtbo.img
BOARD_INCLUDE_RECOVERY_DTBO := true
BOARD_MKBOOTIMG_ARGS += --base $(BOARD_KERNEL_BASE)
BOARD_MKBOOTIMG_ARGS += --pagesize $(BOARD_KERNEL_PAGESIZE)
BOARD_MKBOOTIMG_ARGS += --kernel_offset $(BOARD_KERNEL_OFFSET)
BOARD_MKBOOTIMG_ARGS += --ramdisk_offset $(BOARD_RAMDISK_OFFSET)
BOARD_MKBOOTIMG_ARGS += --second_offset $(BOARD_KERNEL_SECOND_OFFSET)
BOARD_MKBOOTIMG_ARGS += --tags_offset $(BOARD_KERNEL_TAGS_OFFSET)
BOARD_MKBOOTIMG_ARGS += --dtb $(TARGET_PREBUILT_DTB)
BOARD_MKBOOTIMG_ARGS += --dtb_offset $(BOARD_DTB_OFFSET)
BOARD_MKBOOTIMG_ARGS += --header_version $(BOARD_BOOT_HEADER_VERSION)

# Verified boot
BOARD_AVB_ENABLE := true
BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS += --flag 2
BOARD_AVB_RECOVERY_KEY_PATH := external/avb/test/data/testkey_rsa4096.pem
BOARD_AVB_RECOVERY_ALGORITHM := SHA256_RSA4096
BOARD_AVB_RECOVERY_ROLLBACK_INDEX := 1
BOARD_AVB_RECOVERY_ROLLBACK_INDEX_LOCATION := 1

# Partitions
BOARD_FLASH_BLOCK_SIZE := 262144 # (BOARD_KERNEL_PAGESIZE * 64)
BOARD_BOOTIMAGE_PARTITION_SIZE := 134217728
BOARD_RECOVERYIMAGE_PARTITION_SIZE := 134217728
BOARD_DTBOIMG_PARTITION_SIZE := 33554432
BOARD_CACHEIMAGE_PARTITION_SIZE := 402653184
BOARD_CACHEIMAGE_FILE_SYSTEM_TYPE := ext4

# Dynamic partitions
BOARD_SUPER_PARTITION_SIZE := 9126805504
BOARD_SUPER_PARTITION_GROUPS := qti_dynamic_partitions
BOARD_QTI_DYNAMIC_PARTITIONS_SIZE := 9122611200 # (BOARD_SUPER_PARTITION_SIZE - 4194304) 4MiB overhead
BOARD_QTI_DYNAMIC_PARTITIONS_PARTITION_LIST := system system_ext product vendor odm

BOARD_ROOT_EXTRA_FOLDERS := bluetooth dsp firmware persist
BOARD_SUPPRESS_SECURE_ERASE := true
BOARD_USES_METADATA_PARTITION := true

# File systems
TARGET_USERIMAGES_USE_EXT4 := true
TARGET_USERIMAGES_USE_F2FS := true
TARGET_USERIMAGES_USE_EROFS := true
BOARD_HAS_LARGE_FILESYSTEM := true
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := ext4

# Recovery
TW_INCLUDE_REPACKTOOLS := true
TW_INCLUDE_NTFS_3G := true

# No MTP in the release builds. On the device the recovery's MTP start-up re-programs the USB gadget at about
# 13 s (sys.usb.config none -> mtp,adb: adbd is killed, the controller re-enumerates) and opens the legacy
# /dev/mtp_usb function driver, which fails anyway ("[MTP] Failed to start usb driver!"). The kernel panics
# seen on the phone happened a few seconds later; the debug build (FOX_DEBUG_KERNEL=true) keeps MTP so that
# the original situation can be reproduced. Use adb to copy files (adb pull/push).
ifneq ($(FOX_DEBUG_KERNEL),true)
TW_EXCLUDE_MTP := true
endif

# f2fs compression is enabled on PixelOS userdata (compress_extension=apk,apex,so)
PRODUCT_FS_COMPRESSION := 1

# Build variants (export FOX_VARIANT before 'lunch'):
#   (unset)  full build, with /data decryption for PixelOS
#   nocrypt  same recovery with the whole decryption stack left out. Meant for isolating boot
#            problems: it never touches qseecomd / keymaster / the metadata-encrypted /data.
ifeq ($(FOX_VARIANT),nocrypt)
TOCO_NO_CRYPTO := true
endif

# Crypto - PixelOS userdata uses (see its fstab):
#   fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized+wrappedkey_v0
#   metadata_encryption=aes-256-xts:wrappedkey_v0, keydirectory=/metadata/vold/metadata_encryption
ifneq ($(TOCO_NO_CRYPTO),true)
TW_INCLUDE_CRYPTO := true
TW_INCLUDE_CRYPTO_FBE := true
TW_USE_FSCRYPT_POLICY := 2
TW_INCLUDE_FBE_METADATA_DECRYPT := true
BOARD_USES_QCOM_FBE_DECRYPTION := true
endif

BUILD_BROKEN_MISSING_REQUIRED_MODULES := true
