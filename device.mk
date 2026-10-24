#
# Copyright (C) 2026 The OrangeFox Recovery Project
#
# SPDX-License-Identifier: Apache-2.0
#

# Display
TARGET_SCREEN_HEIGHT := 2340
TARGET_SCREEN_WIDTH := 1080

PRODUCT_PACKAGES += \
    fastbootd \
    android.hardware.fastboot@1.0-impl-mock

# Decryption stack (omitted in the 'nocrypt' variant, see BoardConfig.mk)
ifneq ($(FOX_VARIANT),nocrypt)
PRODUCT_PACKAGES += \
    qcom_decrypt \
    qcom_decrypt_fbe
endif

# Launched with Android 10
PRODUCT_SHIPPING_API_LEVEL := 29

# Assert
TARGET_OTA_ASSERT_DEVICE := toco

TARGET_COPY_OUT_VENDOR := vendor

PRODUCT_USE_DYNAMIC_PARTITIONS := true

# Crypto
ifneq ($(FOX_VARIANT),nocrypt)
TW_INCLUDE_CRYPTO := true
TW_INCLUDE_CRYPTO_FBE := true
TW_INCLUDE_FBE_METADATA_DECRYPT := true
endif
PLATFORM_SECURITY_PATCH := 2099-12-31
VENDOR_SECURITY_PATCH := 2099-12-31
PLATFORM_VERSION := 99.87.36
PLATFORM_VERSION_LAST_STABLE := $(PLATFORM_VERSION)

# Recovery
TARGET_RECOVERY_PIXEL_FORMAT := "RGBX_8888"
TARGET_RECOVERY_FSTAB := $(DEVICE_PATH)/recovery/root/system/etc/recovery.fstab

# libion is needed by libQSEEComAPI (qseecomd/keymaster); libxml2 by libdrmfs
TARGET_RECOVERY_DEVICE_MODULES += libion libxml2

RECOVERY_LIBRARY_SOURCE_FILES += \
    $(TARGET_OUT_SHARED_LIBRARIES)/libion.so \
    $(TARGET_OUT_SHARED_LIBRARIES)/libxml2.so

# TWRP specific build flags
TW_THEME := portrait_hdpi
RECOVERY_SDCARD_ON_DATA := true
TARGET_RECOVERY_QCOM_RTC_FIX := true
TW_EXCLUDE_DEFAULT_USB_INIT := true
TW_EXTRA_LANGUAGES := true
TW_INCLUDE_NTFS_3G := true
TW_USE_TOOLBOX := true
TW_INCLUDE_RESETPROP := true
TW_INPUT_BLACKLIST := "hbtp_vm"
TW_BRIGHTNESS_PATH := "/sys/class/backlight/panel0-backlight/brightness"
TW_MAX_BRIGHTNESS := 2047
TW_DEFAULT_BRIGHTNESS := 1200
TWRP_INCLUDE_LOGCAT := true
TARGET_USES_LOGD := true
TARGET_USES_MKE2FS := true
TW_EXCLUDE_APEX := true
TW_INCLUDE_FASTBOOTD := true
TW_NO_HAPTICS := true
# Both reference trees for SM6150-family Xiaomi devices (sweet, miatoll) set these: never put the
# Qualcomm SDE display into DPMS-off from the screen timeout (the brightness is still dimmed to 0),
# and cap the GUI loop at the panel's 60 Hz.
TW_NO_SCREEN_BLANK := true
TW_FRAMERATE := 60

# Properties
TW_OVERRIDE_SYSTEM_PROPS := \
    "ro.build.fingerprint=ro.system.build.fingerprint;ro.build.version.incremental"
