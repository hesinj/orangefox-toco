# Comparing kernels and ramdisks honestly

## Contents
1. Kernels: what not to trust, what to compare
2. Kernel features by markers
3. Ramdisk size, compression and placement
4. Boot image header facts worth checking
5. Checking a ROM's boot partition against the release

## 1. Kernels
* **Do not trust the embedded configuration** (`/proc/config.gz`, IKCONFIG). A prebuilt kernel can carry a stale blob: both the ROM vendor's kernel and our rebuild embedded the same 4.14.180 configuration (it said `CONFIG_LOCALVERSION="-perf"`, `SDCARD_FS=y`)
  that described neither of them. A "721 differing options" finding built on it was wrong and withdrawn.
* **Compare what the kernel prints**: `scripts/compare_kernel_strings.sh A B` compares readable messages (printk formats, option names, driver messages). Same source and configuration: a handful of differences (12 vs 4 of about 18,200 on the reference pair: the banner and compiler-folded format strings).
  Different kernels: thousands (6235 vs 4888 between the old stock kernel and the ROM's).
* **Symbols** for finer comparison: `pip install vmlinux-to-elf`, `vmlinux-to-elf Image out.elf`, then `nm`/`readelf -s` (kernels with kallsyms only).
* The banner (`strings Image | grep 'Linux version'`) gives compiler, linker and build time: it is the quickest way to know whether two images were built by the same CI.
* `scripts/` of `recovery-fbe-decryption`: `kernel_marker_check.sh` tells whether a kernel has fscrypt v2, dm-default-key, wrapped keys, f2fs compression, EROFS.

## 2. Kernel features by markers
Markers are strings only a kernel with the feature contains: `fscrypt-provisioning` (fscrypt v2), `wrappedkey_v0`, `dm-default-key`, `inlinecrypt`, `blk-crypto`, `compress_algorithm`, `erofs`, `fs-verity`.
The old stock kernel of the reference phone had none; the ROM's kernel has all. Absence of a marker in a stripped kernel can be a false negative; presence is reliable.

## 3. Ramdisk size, compression and placement
* The Qualcomm bootloader loads the ramdisk **top-down** and the end address is fixed (on the reference phone 0x855FF000, just below the `hyp_region` at 0x85700000), so a bigger ramdisk starts lower, closer to the kernel image. `/proc/device-tree/chosen/linux,initrd-start/end` shows the range; `Freeing initrd memory: N K` in dmesg shows its size.
  The ROM's recovery ramdisk was 16 MB, the first OrangeFox images 28.6 MB; the LZMA ramdisk 18.2 MB.
* The kernel can only unpack what it was built for (`CONFIG_RD_GZIP/BZIP2/LZMA/XZ/LZO/LZ4/ZSTD`; the facts script prints them). Check an LZMA ramdisk with the kernel's own decoder: `scripts/unlzma_check/`. `lzma -9` produces a legacy `.lzma` stream (magic `5d 00 00`); an `xz` stream (magic `fd 37 7a 58 5a`) is rejected by a kernel without RD_XZ.
* Whether size matters is unproven; it was changed together with other things (`triage-ladder.md`).

## 4. Boot image header facts worth checking (`unpack_bootimg.py`, header v2)
kernel/ramdisk/dtb sizes, `os_version`/`os_patch_level` (the patch level goes to the Keymaster trusted app on some stacks: a recovery with a high fake value is fine, an installed boot image with a *lower* value than the keys' is not), the command line, `recovery_dtbo` size.
A recovery image with its own `recovery_dtbo` boots even when the `dtbo` partition is damaged; a normal boot uses the partition: a good recovery says nothing about the `dtbo` partition.

## 5. Checking a ROM's boot partition against the release
* The release's `boot-*.img`, `dtbo-*.img`, `recovery-*.img` are published whole-partition-sized (128 MiB / 32 MiB / 128 MiB on the reference phone): `sha256sum` of the partition on the phone equals the file hash when the phone has exactly that image (verified for `recovery` and `dtbo` on the reference phone).
* On the phone (recovery with root): `sha256sum /dev/block/bootdevice/by-name/boot`; or copy the first 4 KiB (`dd bs=4096 count=1`) and read the header: sizes of kernel and ramdisk identify the build.
* `avbtool info_image --image <vbmeta partition copy>` lists the hash descriptors (partition names, sizes, digests, salts), flags (3 = verification and hashtree disabled), rollback index and the chained partitions; `hdr-vbmeta*.bin` of the Android diagnosis script feed it.
