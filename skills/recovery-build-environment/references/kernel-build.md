# Kernels: reuse, rebuild, debug

## Contents
1. Reuse the ROM's kernel binary when you can
2. Building a kernel with the in-tree toolchains
3. Outputs and how they enter the recovery
4. The debug kernel (KASAN + SLUB debug + page poisoning)
5. The size budget
6. Licence duties

## 1. Reuse the ROM's kernel binary when you can
The recovery must read the filesystem the ROM wrote, and the ROM's own kernel is the one that was tested with it. On the reference phone the stock (older MIUI 4.14.117) kernel lacked fscrypt v2, blk-crypto, dm-default-key and wrapped keys; the PixelOS release kernel (4.14.356) has them all.
The default of the reference recovery is the ROM's `kernel` blob **byte for byte** (`unpack_bootimg.py --boot_img boot-xxxx.img` gives `kernel`), `verify_image.sh` with `KERNEL_SHA256=...` proves it is untouched. Rebuilding adds a second variable (compiler, linker, config drift) to a port that already has many.
Rebuild only when: the ROM has no usable kernel binary, you need a config option the binary lacks, or you need a debug kernel.
Do not trust the embedded configuration (`/proc/config.gz`, IKCONFIG) of a prebuilt kernel to rebuild it: both the ROM's kernel and the rebuild embedded the same stale 4.14.180 configuration (`recovery-boot-debugging/references/kernel-ramdisk-comparison.md`). The defconfig comes from the kernel source repository, the commit from the ROM's sources (the binary does not record it).

## 2. Building a kernel with the in-tree toolchains
`scripts/build_kernel.sh` (template, copy next to the device tree). Environment: `SRC` (kernel checkout), `OUT` (build directory), `FOX` (OrangeFox tree: clang `clang-r416183b`, gcc 4.9 binutils), `DEFCONFIG`, optional `FRAGMENT`.
```sh
SRC=~/kernel/src OUT=~/kernel/out DEFCONFIG=toco_defconfig scripts/build_kernel.sh      # release
FRAGMENT=debug.fragment SRC=... OUT=... DEFCONFIG=... scripts/build_kernel.sh            # debug
```
Two flags are not optional with clang 12 on a 4.14 tree (verified): `CROSS_COMPILE_COMPAT=arm-linux-androideabi-` (otherwise the 32-bit vDSO links with the host `ld`: "cannot represent machine arm") and `OBJCOPY=llvm-objcopy` (the 64-bit `objcopy` cannot process the 32-bit vDSO ELF).
Last line: `KERNEL_BUILD_OK` or `KERNEL_BUILD_FAILED <step>`. A rebuild with clang 12.0.5 + GNU ld 2.27 against the ROM's clang 21 + LLD 21 kernel of the same source and configuration differed in 12 of about 18,200 messages (banner and folded format strings only): the same kernel, built differently.

## 3. Outputs and how they enter the recovery
* `arch/arm64/boot/Image.gz` -> `prebuilt/Image.gz` (or the name the device tree's `BoardConfig.mk` expects for `TARGET_PREBUILT_KERNEL`).
* The device tree blob (`xiaomi-sdmmagpie.dtb` on the reference phone) -> `prebuilt/dtb`.
* Overlay -> `dtbo.img` with AOSP's tool: `python3 mkdtboimg.py create --page_size=4096 -o prebuilt/dtbo.img <overlay>.dtbo`. A recovery image carries its own `recovery_dtbo`; the `dtbo` partition of the phone is not touched by `fastboot boot` or by flashing `recovery`.
* `verify_image.sh` compares the image's kernel / dtb / recovery_dtbo with these files.

## 4. The debug kernel
`debug.fragment` (appended to `.config`, then `olddefconfig`): `KASAN` (generic, outline), `SLUB_DEBUG`, `DEBUG_LIST`, `BUG_ON_DATA_CORRUPTION`, a 2 MiB log buffer, `PAGE_POISONING`. Command line additions: `slub_debug=FZPU kasan_multi_shot nokaslr panic=0`.
What each is for: KASAN reports a bad write with the allocation and free stacks; `PAGE_POISONING` fills free pages with a pattern and reports when something outside the CPU (a DMA engine, firmware) wrote into free memory, with the bytes written; `panic=0` freezes instead of restarting so that pstore keeps the log (`recovery-boot-debugging`).
`assets/debug-kernel.patch` is the patch used on the reference kernel (a 4.14 Qualcomm tree): it
* makes `KASAN_STACK_ENABLE` default to off (that tree has no `CC_IS_CLANG`, so the symbol cannot be switched off from the config);
* drops global-variable redzones (`asan-globals=0`);
* adds `KASAN_ONLY` to `scripts/Makefile.lib`: a list of directory patterns, everything else is built uninstrumented (section 5);
* stops the Qualcomm WLAN driver from referencing `__qdf_bug()` (defined only in the driver's debug build; `CONFIG_SLUB_DEBUG=y` made the default profile ask for it: link error).
The last hunk (the WLAN driver) is specific to that tree; the others are generic for a 4.14 KASAN build. When `FRAGMENT` is set, `build_kernel.sh` exports `KASAN_ONLY` with the default list of the reference port (kernel, mm, lib, security, crypto, drivers/md, block, scsi, input, usb, gpu/drm, soc, fs/*, net/core ...; override it with `KASAN_ONLY='pattern% pattern%'`, make `%` patterns, a bare word is an exact directory). Adapt it to the subsystem under suspicion, and keep the footprint within the budget of section 5.
Apply with `git apply --check` first. Never ship a debug image as a release: it is slower, larger and froze differently.

## 5. The size budget
The bootloader places the kernel at `0x80080000` and the first firmware-reserved region (`hyp_region`) starts at `0x85700000`: the kernel **and its bss** must stay below about 86 MiB. Measured: release kernel 42 MB + 7 MB bss (48 MB footprint); everything instrumented 87 MB + 20 MB bss (107 MB, does not fit); KASAN on selected directories fits.
So: instrument only the directories under suspicion (`KASAN_ONLY`), and read the address map of a boot (`/proc/iomem` in the recorder header) before assuming a budget on another SoC; the numbers are specific to the reference SoC.

## 6. Licence duties
A kernel is GPL-2.0. A recovery image that contains a kernel binary you redistribute needs the corresponding source offer: link the kernel repository and the commit, note whether the binary is the ROM's (byte-for-byte copy, record its sha256) or built here (commit, config, build script). See `shipping.md`.
