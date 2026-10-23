#!/bin/bash
# Builds the PixelOS (Vantom) 4.14 kernel for toco with the toolchains from the OrangeFox tree.
set -o pipefail
FOX=/home/user/fox_12.1
CL=$FOX/prebuilts/clang/host/linux-x86/clang-r416183b
GCC64=$FOX/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9
GCC32=$FOX/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9
SRC=/home/user/work/kernel_pos/src
OUT=/home/user/work/kernel_pos/out
export PATH=$CL/bin:$GCC64/bin:$GCC32/bin:$PATH
export LC_ALL=C KBUILD_BUILD_USER=toco-port KBUILD_BUILD_HOST=orangefox
cd "$SRC" || exit 1
MK="make -j$(nproc) O=$OUT ARCH=arm64 SUBARCH=arm64 CC=clang CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-android- CROSS_COMPILE_ARM32=arm-linux-androideabi- CROSS_COMPILE_COMPAT=arm-linux-androideabi- OBJCOPY=llvm-objcopy HOSTCC=gcc HOSTCXX=g++"
mkdir -p "$OUT"
echo "== defconfig"; $MK toco_defconfig || { echo "KERNEL_BUILD_FAILED defconfig"; exit 1; }
echo "== Image.gz dtbs"; $MK Image.gz dtbs || { echo "KERNEL_BUILD_FAILED build"; exit 1; }
echo KERNEL_BUILD_OK
