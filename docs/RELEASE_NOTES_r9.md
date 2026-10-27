**Pre-release `r9`: `r8` plus one kernel parameter, `initcall_blacklist=drv260x_driver_init`. It has not been booted yet.** OrangeFox R12.0 (unofficial, `fox_12.1` build system) for the Xiaomi Mi Note 10 Lite (toco), aimed at PixelOS (Android 16) `/data`.

### Why `r9`
The freezes, black screens and restarts of `r2` to `r8` were kernel heap corruption. On 27 October a debug kernel (KASAN + SLUB debugging) showed who writes into freed memory: the vendor haptics driver `drv260x` (the DRV2604 vibration chip, I2C `3-005a`). On the phone that sent the logs the I2C bus 3 no longer answers (`Bus arbitration lost, clock line undriveable`; the flash-LED chip on the same bus fails too). The driver's probe then fails, its error path frees device-managed memory by hand (a double free), and a firmware load that it leaves queued later writes the vibration firmware into the freed object. The same corruption kept Android from booting (`bootstrap-apexd-failed`, `init_user0_failed`). Details and the proof: `docs/TROUBLESHOOTING.md`, "The writer is found".

With `initcall_blacklist=drv260x_driver_init` the driver is never initialised, so none of this happens. On that phone the same parameter in the installed ROM's boot image made Android boot again, without a factory reset. The recovery does not use the chip (`TW_NO_HAPTICS`), so it loses nothing; on a phone whose I2C bus works the parameter only skips a probe that would have succeeded.

### Changes since `r8`
- The kernel command line has `initcall_blacklist=drv260x_driver_init` added (`BoardConfig.mk`).
- Nothing else. For both variants the kernel, the dtb and the dtbo are byte-identical to `r8`'s, and the files of the ramdisk are the same apart from the build date and build id (`default.prop`, `prop.default`, `system/etc/fox.cfg` and the checksum list that names it). This was checked by unpacking the images of both releases and comparing them file by file; the compressed ramdisks differ in size (18,219,224 against 18,216,546 bytes for the full image, 16,067,468 against 16,057,762 for `-nocrypt`), which was not traced further.
- `scripts/build_fox.sh` now sets `FOX_LZMA_RAMDISK=true` itself. `r8` had it exported by hand, and a first `r9` build without it came out with the 28.6 MB gzip ramdisk.

### Files
- `OrangeFox-R12.0-Unofficial-toco-r9.img` / `.zip` - full build (decryption stack)
- `OrangeFox-R12.0_nocrypt-Unofficial-toco-r9.img` / `.zip` - no decryption stack

```
dc1b8ebcc88142b20eff4ab8465474181fd09997e282710bd2345eef254cd4ba  OrangeFox-R12.0-Unofficial-toco-r9.img
7627d1fa3b984d07b0d69f479c1cbfad5e6a91a15e9126ab9b712888845f886b  OrangeFox-R12.0_nocrypt-Unofficial-toco-r9.img
84cf89d2f83cbf64b7126c24005ed13cca4c71c42c688e84df52a6dda68c0874  OrangeFox-R12.0-Unofficial-toco-r9.zip
954d41e6ee16d1306f910fd2866768b5f65b594c6fbf78c92ad481529a1f9139  OrangeFox-R12.0_nocrypt-Unofficial-toco-r9.zip
```
Each `.img` is exactly 128 MiB (the recovery partition size) with an AVB footer made with the AOSP test key. Static checks (`tools/verify_image.sh`): 28 of 28 for the full image, 24 of 24 for `-nocrypt` (the count is one higher than for `r8` because of a new check that the command line has the parameter). Both ramdisks are LZMA-compressed.

### Try it
`fastboot boot` does not change anything on the phone:
```
fastboot boot OrangeFox-R12.0-Unofficial-toco-r9.img
```
Boot it several times in a row (back to the bootloader each time) and count how many came up. With the driver kept out the black screens and restarts should be gone, but that is the expectation, not a result: `r9` has not been run on the phone yet. If it still fails, run `tools/toco-logs.bat` after a boot that came up and send the files.

Do not use Format Data or Wipe: while `/data` is not decrypted they would destroy it.

### What stays broken
The parameter only keeps the broken chip's driver from damaging memory. It does not repair the I2C bus: vibration and the camera flash LED stay dead until the hardware is repaired.

### Limits
- Targets PixelOS-style FBE (fscrypt v2, inline crypto, wrapped keys). Data encrypted by stock MIUI will not decrypt.
- The recovery uses Android 12-era decryption code; reading keys written by Android 16 is unverified.
- Static checks only for the images.

Kernel: `prebuilt/Image-pixelos.gz` is PixelOS's published GPL-2.0 kernel (source: PixelOS-Devices/android_kernel_xiaomi_sm6150); the own build is the same repository at f7d0768 with the config and build script in `kernel/`. The OrangeFox change is `patches/0001-toco-startup-hardening.patch`. See `NOTICE.md` for provenance, including the proprietary vendor binaries.
