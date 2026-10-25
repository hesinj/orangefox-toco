#!/bin/bash
# Build an OrangeFox (fox_12.1) recovery for one device.
#   usage: build_fox.sh DEVICE [full|nocrypt] [debug]
#     DEVICE   the codename of the device tree (device/<oem>/<DEVICE>); lunch target twrp_<DEVICE>-eng
#     full     (default) the decryption stack built in
#     nocrypt  FOX_VARIANT=nocrypt: no decryption stack. Always build and test this twin when a new recovery misbehaves
#     debug    FOX_DEBUG_KERNEL=true for trees that carry a debug-kernel switch (see recovery-boot-debugging)
#   environment: FOX (OrangeFox tree, default ~/fox_12.1), plus any FOX_* switch of the device tree exported by the caller
#                (FOX_LZMA_RAMDISK=true, FOX_ALT_KERNEL=true ...)
# Result: $FOX/out/target/product/<DEVICE>/OrangeFox-*.img and .zip. The last lines are FOX_BUILD_OK or FOX_BUILD_FAILED <step>.
DEVICE="${1:?usage: build_fox.sh DEVICE [full|nocrypt] [debug]}"
FOX="${FOX:-$HOME/fox_12.1}"
cd "$FOX" || exit 1
export LC_ALL=C ALLOW_MISSING_DEPENDENCIES=true FOX_BUILD_DEVICE="$DEVICE"
export OUT_DIR="$FOX/out"
case "${2:-full}" in
  full|"") unset FOX_VARIANT ;;
  *)       export FOX_VARIANT="$2" ;;
esac
if [ "${3:-}" = debug ]; then export FOX_DEBUG_KERNEL=true; else unset FOX_DEBUG_KERNEL; fi
echo "BUILD $DEVICE VARIANT: ${FOX_VARIANT:-<full>}   DEBUG KERNEL: ${FOX_DEBUG_KERNEL:-no}"
# staging directories of an earlier variant must not leak into this image (stale libraries, decrypt init files)
P="$OUT_DIR/target/product/$DEVICE"
for d in root recovery fake_packages; do [ -d "$P/$d" ] && rm -rf "$P/$d"; done
set +e
# shellcheck disable=SC1091
source build/envsetup.sh
lunch "twrp_${DEVICE}-eng" || { echo "FOX_BUILD_FAILED lunch"; exit 1; }
mka adbd recoveryimage
rc=$?
echo "mka exit code: $rc"
[ $rc -eq 0 ] && echo FOX_BUILD_OK || echo "FOX_BUILD_FAILED mka"
exit $rc
