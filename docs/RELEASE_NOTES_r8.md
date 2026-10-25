**Pre-release `r8`. On the phone it booted, decrypted `/data` (metadata layer during boot, then the user's password) and allowed `adb pull` of the internal storage; that is one reported session, so whether it now boots reliably is not established.** OrangeFox R12.0 (unofficial, `fox_12.1` build system) for the Xiaomi Mi Note 10 Lite (toco), aimed at PixelOS (Android 16) `/data`.

### What `r7` showed
`r7` (PixelOS's release kernel plus extra precautions) failed in the three boots that were tried. Its black-box logs (`/cache/toco-bb`) show one kernel panic at 5.66 s, in the `recovery` process right after its first mount of a logical partition, and two boots that stopped about a second after the recorder's header, at the time the decryption services start. On the same phone PixelOS's own `recovery.img` always boots and `r3-nocrypt` usually does. Details: `docs/TROUBLESHOOTING.md`, "Sixth report".

### Changes since `r7`
- The kernel command line is PixelOS's own recovery command line plus what this recovery needs (`androidboot.usbcontroller`, `androidboot.dynamic_partitions`, `androidboot.selinux=permissive`, `panic=0`). `retain_initrd nokaslr` are gone.
- `init` no longer switches the CPUs to `schedutil`.
- The black-box recorder no longer reads CPU frequencies, thermal zones, the battery or kernel stacks (it reads procfs, init properties and the kernel log), and it logs where the decryption chain is (`svc:` line: `prepdecrypt`, `qseecomd`, keymaster, keystore2).
- **The ramdisk is LZMA-compressed** (`FOX_LZMA_RAMDISK=true`): 18.2 MB for the full image and 16.1 MB for `-nocrypt`, against 28.6 MB and 25.2 MB, so it loads about as much as PixelOS's own 16 MB recovery. The kernel's own `unlzma` source was run on the finished ramdisks and reproduces them exactly. Boot takes a few seconds longer.
- The kernel is still PixelOS's own release kernel, byte for byte (`prebuilt/Image-pixelos.gz`).

### Files
- `OrangeFox-R12.0-Unofficial-toco-r8.img` / `.zip` - full build (decryption stack)
- `OrangeFox-R12.0_nocrypt-Unofficial-toco-r8.img` / `.zip` - no decryption stack

```
19a509ecaa7aae7443b87ce7db5a375fa01e8ae60cfb2bfe755071b932fd8ce1  OrangeFox-R12.0-Unofficial-toco-r8.img
1531b04e66410203f9c2a3c551cbdfc227cdbf99654981517361b15ea3ef0411  OrangeFox-R12.0_nocrypt-Unofficial-toco-r8.img
d4ac0bb89bfc12f37617e04e25a11fbccfe4d5a2b1ef4bbcff5fef2968499b12  OrangeFox-R12.0-Unofficial-toco-r8.zip
30e7cf550eaf1405b020939507d12c0aca0ce46f9655818c29e44fcd779b25d9  OrangeFox-R12.0_nocrypt-Unofficial-toco-r8.zip
```
Each `.img` is exactly 128 MiB (the recovery partition size) with an AVB footer made with the AOSP test key. Static checks (`tools/verify_image.sh`): 27 of 27 for the full image, 23 of 23 for `-nocrypt`.

### Try it
`fastboot boot` does not change anything on the phone:
```
fastboot boot OrangeFox-R12.0-Unofficial-toco-r8.img
```
Boot it **six times in a row** (back to the bootloader each time) and count how many came up. Then, whatever the count, run `tools/toco-logs.bat` once after a boot that came up: `pstore.txt` holds the console of the boot before it and `toco-bb/` the black-box files, including how far the decryption chain got.

Do not use Format Data or Wipe: while `/data` is not decrypted they would destroy it.

### Limits
- Targets PixelOS-style FBE (fscrypt v2, inline crypto, wrapped keys). Data encrypted by stock MIUI will not decrypt.
- The recovery uses Android 12-era decryption code; reading keys written by Android 16 is unverified.
- Static checks only for the images.

Kernel: `prebuilt/Image-pixelos.gz` is PixelOS's published GPL-2.0 kernel (source: PixelOS-Devices/android_kernel_xiaomi_sm6150); the own build is the same repository at f7d0768 with the config and build script in `kernel/`. The OrangeFox change is `patches/0001-toco-startup-hardening.patch`. See `NOTICE.md` for provenance, including the proprietary vendor binaries.
