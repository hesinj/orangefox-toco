#
#      This file is part of the OrangeFox Recovery Project
#      Copyright (C) 2021-2026 The OrangeFox Recovery Project
#
#      OrangeFox is free software: you can redistribute it and/or modify
#      it under the terms of the GNU General Public License as published by
#      the Free Software Foundation, either version 3 of the License, or
#      any later version.
#
#      This software is released under GPL version 3 or any later version.
#      See <http://www.gnu.org/licenses/>.
#
FDEVICE="toco"

fox_get_target_device() {
   if echo "$BASH_SOURCE" | grep -q "/$FDEVICE"; then
      FOX_BUILD_DEVICE="$FDEVICE"
   elif set | grep BASH_ARGV | grep -q "\b$FDEVICE\b"; then
      FOX_BUILD_DEVICE="$FDEVICE"
   elif echo "$BASH_SOURCE[0]" | grep -q "/$FDEVICE"; then
      FOX_BUILD_DEVICE="$FDEVICE"
   elif echo "$0" | grep -q "$FDEVICE"; then
      FOX_BUILD_DEVICE="$FDEVICE"
   fi
}

if [ -z "$1" -a -z "$FOX_BUILD_DEVICE" ]; then
   fox_get_target_device
fi

if [ "$1" = "$FDEVICE" -o "$FOX_BUILD_DEVICE" = "$FDEVICE" ]; then

      export TW_DEFAULT_LANGUAGE="en"
      export LC_ALL="C"
      export ALLOW_MISSING_DEPENDENCIES=true

      # dynamic partitions: logical partitions are mapped under /dev/block/mapper
      export FOX_RECOVERY_SYSTEM_PARTITION="/dev/block/mapper/system"
      export FOX_RECOVERY_VENDOR_PARTITION="/dev/block/mapper/vendor"

      export FOX_USE_NANO_EDITOR=1
      export FOX_ENABLE_APP_MANAGER=1
      export FOX_USE_BASH_SHELL=1
      export FOX_ASH_IS_BASH=1
      export FOX_USE_TAR_BINARY=1
      export FOX_USE_LZ4_BINARY=1
      export FOX_USE_ZSTD_BINARY=1
      export FOX_USE_XZ_UTILS=1
      export FOX_DELETE_AROMAFM=1

      export FOX_SETTINGS_ROOT_DIRECTORY=/data/recovery
      export FOX_MISCELLANEOUS_ROOT_DIRECTORY=/sdcard

      # build info
      export FOX_BUILD_TYPE="Unofficial"
      export OF_MAINTAINER="toco-port"

else
   if [ -z "$FOX_BUILD_DEVICE" -a -z "$BASH_SOURCE" ]; then
      echo "I: This script requires bash. Not processing the $FDEVICE $(basename $0)"
   fi
fi
#
