#
#	OrangeFox-specific settings for Xiaomi Mi Note 10 Lite (toco)
#
#	This file is part of the OrangeFox Recovery Project device configuration
#

# General
OF_USE_GREEN_LED := 0
OF_NO_TREBLE_COMPATIBILITY_CHECK := 1
OF_NO_MIUI_PATCH_WARNING := 1
OF_DONT_PATCH_ENCRYPTED_DEVICE := 1
OF_ENABLE_LPTOOLS := 1
OF_QUICK_BACKUP_LIST := /boot;/data;/dtbo;

# No automatic writes to boot/system. OF_PATCH_AVB20 is deliberately NOT set: with it,
# OrangeFox hex-patches the real boot partition's AVB footer before every reboot, and the
# zip installer's "fresh install" path repacks the boot image. Both are unwanted while this
# recovery is still untested on hardware.
OF_DONT_PATCH_ON_FRESH_INSTALLATION := 1

# Magisk & boot patching (only used when the user asks for a patch)
OF_USE_MAGISKBOOT := 1
OF_USE_MAGISKBOOT_FOR_ALL_PATCHES := 1

# OTA
OF_SUPPORT_ALL_BLOCK_OTA_UPDATES := 1
OF_FIX_OTA_UPDATE_MANUAL_FLASH_ERROR := 1
OF_DISABLE_MIUI_OTA_BY_DEFAULT := 1

# try to prevent potential data format errors
OF_UNBIND_SDCARD_F2FS := 1

# Decryption (FBE v2, metadata encryption, hardware-wrapped keys - PixelOS)
OF_FBE_METADATA_MOUNT_IGNORE := 1

# f2fs compression (kernel has CONFIG_F2FS_FS_COMPRESSION; fstab has fscompress)
OF_ENABLE_FS_COMPRESSION := 1

# maximum permissible splash image size (in kilobytes); do *NOT* increase!
OF_SPLASH_MAX_SIZE := 130

# screen: 1080x2340 with a punch-hole camera
OF_SCREEN_H := 2340
OF_STATUS_H := 100
OF_STATUS_INDENT_LEFT := 48
OF_STATUS_INDENT_RIGHT := 48
OF_HIDE_NOTCH := 1
OF_CLOCK_POS := 1
