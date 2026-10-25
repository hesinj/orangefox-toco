#!/bin/bash
# Kernel build template for an Android 4.x/5.x ARM64 kernel with the toolchains that ship inside the OrangeFox tree.
# Copy it next to the device tree (kernel/build_kernel.sh) and fill the variables that differ. Proven on a 4.14 Qualcomm kernel (clang 12 + gcc 4.9 binutils).
#   build_kernel.sh                         release kernel
#   FRAGMENT=debug.fragment build_kernel.sh debug kernel: the fragment's options are appended to .config, then olddefconfig
# Environment (defaults in brackets):
#   FOX [~/fox_12.1]  OrangeFox tree (toolchains)     SRC  kernel checkout     OUT  build directory (not /dev/shm: see references/kernel-build.md)
#   DEFCONFIG [device_defconfig]   CLANG_DIR [clang-r416183b]   JOBS [nproc]   DTBS [yes]
# Last line: KERNEL_BUILD_OK or KERNEL_BUILD_FAILED <step>. Outputs: $OUT/arch/arm64/boot/Image.gz (+ dts/*.dtb).
set -o pipefail
FOX=${FOX:-$HOME/fox_12.1}
CL=$FOX/prebuilts/clang/host/linux-x86/${CLANG_DIR:-clang-r416183b}
GCC64=$FOX/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9
GCC32=$FOX/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9
SRC=${SRC:?kernel source directory}
OUT=${OUT:?build directory}
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=$CL/bin:$GCC64/bin:$GCC32/bin:$PATH
export LC_ALL=C KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-recovery-port} KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-orangefox}
cd "$SRC" || exit 1
# CROSS_COMPILE_COMPAT: with clang the 32-bit vDSO otherwise links with the host ld ("cannot represent machine arm").
# OBJCOPY=llvm-objcopy: the 64-bit objcopy cannot process the 32-bit vDSO ELF.
MK="make -j${JOBS:-$(nproc)} O=$OUT ARCH=arm64 SUBARCH=arm64 CC=clang CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-android- CROSS_COMPILE_ARM32=arm-linux-androideabi- CROSS_COMPILE_COMPAT=arm-linux-androideabi- OBJCOPY=llvm-objcopy HOSTCC=gcc HOSTCXX=g++"
mkdir -p "$OUT"
echo "== defconfig"; $MK "${DEFCONFIG:-device_defconfig}" || { echo "KERNEL_BUILD_FAILED defconfig"; exit 1; }
if [ -n "${FRAGMENT:-}" ]; then
  echo "== merging $FRAGMENT"
  cat "$HERE/$FRAGMENT" >> "$OUT/.config"
  $MK olddefconfig || { echo "KERNEL_BUILD_FAILED olddefconfig"; exit 1; }
  # assets/debug-kernel.patch adds KASAN_ONLY to scripts/Makefile.lib: only directories matching one of these make patterns are
  # instrumented. Instrumenting everything makes a kernel too big for the memory below the hypervisor region (references/kernel-build.md).
  export KASAN_ONLY="${KASAN_ONLY-kernel% mm% lib% security% crypto% drivers/md% drivers/base% drivers/block% drivers/scsi% drivers/input% drivers/char% drivers/tty% drivers/usb% drivers/android% drivers/staging/android% drivers/dma-buf% drivers/misc% drivers/soc% drivers/power% drivers/gpu/drm% fs fs/f2fs% fs/ext4% fs/erofs% fs/fat% fs/jbd2% fs/proc% fs/sysfs% fs/configfs% fs/pstore% fs/crypto% fs/devpts% fs/nls% fs/notify% net net/core% net/unix% net/netlink%}"
  echo "== KASAN only in: $KASAN_ONLY"
fi
TARGETS="Image.gz"; [ "${DTBS:-yes}" = yes ] && TARGETS="Image.gz dtbs"
echo "== $TARGETS"; $MK $TARGETS || { echo "KERNEL_BUILD_FAILED build"; exit 1; }
echo KERNEL_BUILD_OK
