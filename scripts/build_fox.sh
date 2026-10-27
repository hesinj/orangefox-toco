#!/bin/bash
# Build the OrangeFox (fox_12.1) recovery for toco.
#   usage: build_fox.sh [full|nocrypt] [debug]
#     full     (default) with the decryption stack
#     nocrypt  without any decryption stack
#     debug    use prebuilt-debug/ (kernel built with kernel/debug.fragment: KASAN + SLUB debugging); this build
#              keeps MTP and uses panic=0 so that a kernel panic freezes the phone and can be read back from pstore
# FOX is the OrangeFox 12.1 tree (default /home/user/fox_12.1). The result is copied to $FOX/out/target/product/toco/.
# The ramdisk is LZMA-compressed as in r8 (18 MB instead of 28.6 MB, about what PixelOS's own recovery loads);
# FOX_LZMA_RAMDISK=false builds the gzip ramdisk of r2 to r7.
FOX=${FOX:-/home/user/fox_12.1}
cd "$FOX" || exit 1
export LC_ALL=C ALLOW_MISSING_DEPENDENCIES=true FOX_BUILD_DEVICE=toco
export FOX_LZMA_RAMDISK=${FOX_LZMA_RAMDISK:-true}
export OUT_DIR=$FOX/out
export PATH=/root/bin:$PATH
case "${1:-full}" in
  full|"") unset FOX_VARIANT ;;
  *)       export FOX_VARIANT="$1" ;;
esac
if [ "${2:-}" = debug ]; then export FOX_DEBUG_KERNEL=true; else unset FOX_DEBUG_KERNEL; fi
echo "BUILD VARIANT: ${FOX_VARIANT:-<full>}   DEBUG KERNEL: ${FOX_DEBUG_KERNEL:-no}"
# staging directories of an earlier variant must not leak into this image (stale libraries, decrypt init files)
P=$OUT_DIR/target/product/toco
rm -rf "$P/root" "$P/recovery" "$P/fake_packages"
set +e
source build/envsetup.sh
lunch twrp_toco-eng || { echo "FOX_BUILD_FAILED lunch"; exit 1; }
mka adbd recoveryimage
rc=$?
echo "mka exit code: $rc"
[ $rc -eq 0 ] && echo FOX_BUILD_OK || echo "FOX_BUILD_FAILED mka"
