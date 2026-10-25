**Pre-release `r7` for testing. Whether it stops the random freezes is not known yet; `/data` decryption is not known to work end to end.** OrangeFox R12.0 (unofficial, `fox_12.1` build system) for the Xiaomi Mi Note 10 Lite (toco), aimed at PixelOS (Android 16) `/data`.

### What the last log showed
A boot of `r3-nocrypt` that finally came up carried, in `pstore`, the console of the boot before it (an `r5`/`r6` full image): it had panicked at **1.13 s**, while the kernel was scanning the UFS LUNs, before `init` had started. Same signature as the earlier panics (2.7 s in the display driver, 24 s in a socket buffer allocation): the first eight bytes of a *free* `kmalloc-512` object had been overwritten with high-entropy data, and the next allocation of that object crashed. So the cause is in the kernel or below it, not in the recovery's user space, USB, MTP or the decryption stack. Details: `docs/TROUBLESHOOTING.md`, "Fifth report".

The kernel built here and the kernel in PixelOS's own release are the same source and configuration (their readable messages match except 7 of about 14000); they differ in compiler and linker (clang 12.0.5 + GNU ld 2.27 here, clang 21 + LLD at PixelOS).

### Changes since `r5`/`r6`
- **The kernel is now PixelOS's own release kernel**, byte for byte (`prebuilt/Image-pixelos.gz`, from the `boot-toco_20260609_1626.img` of PixelOS's release, sha256 `abf7b66fd6a3529003f01130c3fa367a92cb1f04e765f08139ed75917ebe1752`): the one that runs on the phone every day. The self-built kernel stays available (`export FOX_OWN_KERNEL=true`). The dtb and dtbo were already identical.
- `retain_initrd nokaslr` on the kernel command line: the kernel keeps the memory the bootloader loaded the ramdisk into instead of freeing it to the allocator, and does not randomise its addresses. Cheap precautions against two ways the corruption could come about.
- `init` switches the CPUs from the kernel's boot governor, `performance` (all eight cores at maximum frequency for as long as the recovery runs), to `schedutil`.
- The black-box recorder (`/cache/toco-bb/boot-N.log`, fetched by `toco-logs.bat`) now starts each boot with a header: kernel version and command line, `/proc/iomem`, where the bootloader put the ramdisk, and a copy of the previous boot's panic log (`pstore-before-boot-N.txt`) so that it survives a boot of another OS in between.
- Optional, not in these images: `export FOX_LZMA_RAMDISK=true` compresses the ramdisk with LZMA (18 MB instead of 28.6 MB).

### Files
- `OrangeFox-R12.0-Unofficial-toco-r7.img` / `.zip` - full build (decryption stack)
- `OrangeFox-R12.0_nocrypt-Unofficial-toco-r7.img` / `.zip` - no decryption stack

```
2fba9196dcb263dd954ee81686697430e4fdd4aed4ef74ba379a47034d3f8636  OrangeFox-R12.0-Unofficial-toco-r7.img
ccecc64fdade2a25c50b58e813d2ddce7113a48d6b782953864e1e02ea4dcc8f  OrangeFox-R12.0_nocrypt-Unofficial-toco-r7.img
4377170d9fd26b3c4fd3d583675f39157c7fbab75f8d1ea0635f23df3b970290  OrangeFox-R12.0-Unofficial-toco-r7.zip
a62b35b510d381f733d45ddaa237e15802be35050d6da2d6ee01b26e94d635e7  OrangeFox-R12.0_nocrypt-Unofficial-toco-r7.zip
```
Each `.img` is exactly 128 MiB (the recovery partition size) with an AVB footer made with the AOSP test key. Static checks (`tools/verify_image.sh`): 28 of 28 for the full image, 24 of 24 for `-nocrypt`.

### Try it
`fastboot boot` does not change anything on the phone:
```
fastboot boot OrangeFox-R12.0-Unofficial-toco-r7.img
```
One boot proves nothing (the earlier builds came up about one time in two): reboot to the bootloader and boot it **five times in a row**. If all five come up the freezes are very likely gone; if one freezes, hold Power until the phone restarts, keep holding Volume-Down to land in fastboot, boot again and, when one comes up, run `tools/toco-logs.bat` (Windows) / `tools/toco-capture.sh` (macOS, Linux): the result holds the panic log (`pstore.txt`) and the black-box files. If it still freezes, the next steps are in `docs/TROUBLESHOOTING.md`: boot PixelOS's own recovery image the same way for comparison, the LZMA ramdisk, the debug image.

Do not use Format Data or Wipe: while `/data` is not decrypted they would destroy it.

### Limits
- Targets PixelOS-style FBE (fscrypt v2, inline crypto, wrapped keys). Data encrypted by stock MIUI will not decrypt.
- The recovery uses Android 12-era decryption code; reading keys written by Android 16 is unverified.
- Static checks only for the images.

Kernel: `prebuilt/Image-pixelos.gz` is PixelOS's published GPL-2.0 kernel (source: PixelOS-Devices/android_kernel_xiaomi_sm6150); the own build is the same repository at f7d0768 with the config and build script in `kernel/`. The OrangeFox change is `patches/0001-toco-startup-hardening.patch`. See `NOTICE.md` for provenance, including the proprietary vendor binaries.
