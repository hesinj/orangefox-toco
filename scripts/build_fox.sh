#!/bin/bash
# Build OrangeFox (fox_12.1) recovery for toco.
#   usage: build_fox.sh [variant]      variant: empty (full) or "nocrypt"
cd /home/user/fox_12.1 || exit 1
export LC_ALL=C ALLOW_MISSING_DEPENDENCIES=true FOX_BUILD_DEVICE=toco
export OUT_DIR=/home/user/fox_12.1/out
export PATH=/root/bin:$PATH
if [ -n "$1" ]; then export FOX_VARIANT="$1"; else unset FOX_VARIANT; fi
echo "BUILD VARIANT: ${FOX_VARIANT:-<full>}"
set +e
source build/envsetup.sh
lunch twrp_toco-eng || { echo "FOX_BUILD_FAILED lunch"; exit 1; }
mka adbd recoveryimage
rc=$?
echo "mka exit code: $rc"
[ $rc -eq 0 ] && echo FOX_BUILD_OK || echo "FOX_BUILD_FAILED mka"
