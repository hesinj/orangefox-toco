#!/bin/bash
# Builds the PixelOS (Vantom) 4.14 kernel for toco with the toolchains from the OrangeFox tree.
#
#   build_kernel.sh                      release kernel (what prebuilt/Image.gz is)
#   FRAGMENT=debug.fragment OUT=... build_kernel.sh
#                                        same kernel plus the options in the fragment (kernel/debug.fragment
#                                        turns on KASAN and SLUB debugging to hunt memory corruption).
#                                        Apply kernel/debug-kernel.patch to SRC first (git apply).
#
# SRC (kernel checkout at SOURCE_COMMIT.txt) and OUT (build directory) can be set from the environment.
set -o pipefail
FOX=${FOX:-/home/user/fox_12.1}
CL=$FOX/prebuilts/clang/host/linux-x86/clang-r416183b
GCC64=$FOX/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9
GCC32=$FOX/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9
SRC=${SRC:-/home/user/work/kernel_pos/src}
OUT=${OUT:-/home/user/work/kernel_pos/out}
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=$CL/bin:$GCC64/bin:$GCC32/bin:$PATH
export LC_ALL=C KBUILD_BUILD_USER=toco-port KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-orangefox}
cd "$SRC" || exit 1
MK="make -j${JOBS:-$(nproc)} O=$OUT ARCH=arm64 SUBARCH=arm64 CC=clang CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-android- CROSS_COMPILE_ARM32=arm-linux-androideabi- CROSS_COMPILE_COMPAT=arm-linux-androideabi- OBJCOPY=llvm-objcopy HOSTCC=gcc HOSTCXX=g++"
mkdir -p "$OUT"
echo "== defconfig"; $MK toco_defconfig || { echo "KERNEL_BUILD_FAILED defconfig"; exit 1; }
if [ -n "$FRAGMENT" ]; then
    echo "== merging $FRAGMENT"
    cat "$HERE/$FRAGMENT" >> "$OUT/.config"
    $MK olddefconfig || { echo "KERNEL_BUILD_FAILED olddefconfig"; exit 1; }
    # debug-kernel.patch lets scripts/Makefile.lib instrument only the directories matching KASAN_ONLY (make
    # patterns). Instrumenting everything makes a kernel too big for the memory below the hypervisor region.
    export KASAN_ONLY="${KASAN_ONLY-kernel% mm% lib% security% crypto% drivers/md% drivers/base% drivers/block% drivers/scsi% drivers/input% drivers/char% drivers/tty% drivers/usb% drivers/android% drivers/staging/android% drivers/dma-buf% drivers/misc% drivers/soc% drivers/power% drivers/gpu/drm% fs fs/f2fs% fs/ext4% fs/erofs% fs/fat% fs/jbd2% fs/proc% fs/sysfs% fs/configfs% fs/pstore% fs/crypto% fs/devpts% fs/nls% fs/notify% net net/core% net/unix% net/netlink%}"
    echo "== KASAN only in: $KASAN_ONLY"
fi
echo "== Image.gz dtbs"; $MK Image.gz dtbs || { echo "KERNEL_BUILD_FAILED build"; exit 1; }
echo KERNEL_BUILD_OK
