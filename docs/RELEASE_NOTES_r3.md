**Pre-release `r3` for testing. `/data` decryption is not known to work.** OrangeFox R12.0 (unofficial, `fox_12.1` build system) for the Xiaomi Mi Note 10 Lite (toco), aimed at PixelOS (Android 16) `/data`.

### Files
- `OrangeFox-R12.0-Unofficial-toco-r3.img` - full build (kernel for PixelOS data, decryption stack), exactly 128 MiB, AVB footer with the AOSP test key
- `OrangeFox-R12.0_nocrypt-Unofficial-toco-r3.img` - same without any decryption stack, to tell kernel/display/touch problems from decryption problems
- `.zip` installers of both, and `SHA256SUMS`

```
dc5696761233771bc38a722289a73297f89cc80728c1ba7e0082ce91bbff9a38  OrangeFox-R12.0-Unofficial-toco-r3.img
6688e06f6d972ab0fe839b19c8aeb7b416dfe10f2289873767a76aade8d60185  OrangeFox-R12.0-Unofficial-toco-r3.zip
2b15d169ff1b92d160a39415017d4fb6ddbfc22adcf0d42192a465315dbc4e27  OrangeFox-R12.0_nocrypt-Unofficial-toco-r3.img
ce3e68830dc96f8f6a280eabc889ab4e670c2b408b342a078be86038a0a19c41  OrangeFox-R12.0_nocrypt-Unofficial-toco-r3.zip
```

### Known state
`r2` was run on a device. It started (display, partitions, vendor props) and then stayed on the OrangeFox logo,
blocked in the decryption of `/data`, while `adb` answered. `r3` does not claim to fix the decryption. It
- gives up on the decryption after 90 s, so the OrangeFox menu and `adb` come up,
- writes the state of the decryption services into `/tmp/recovery.log` (blocks starting with `fox-diag:`),
- mounts the `modem` partition read-only at `/vendor/firmware_mnt`, which the Keymaster library uses,
- no longer carries a stale `libops.so` that `r1`/`r2` had left in the image.

### Try it
Boot it first and keep your current recovery:
```
fastboot boot OrangeFox-R12.0-Unofficial-toco-r3.img
```
Then send `/tmp/recovery.log` (`adb pull /tmp/recovery.log`), or run `tools/toco-logs.bat` (Windows) / `tools/toco-capture.sh` (macOS, Linux) from the repository, which collect everything that helps. See `docs/TROUBLESHOOTING.md`.

Do not use Format Data or Wipe: while `/data` is not decrypted they would destroy it.

### What was checked
Static checks only (`tools/verify_image.sh`, 22/22 for the full image, 18/18 for `-nocrypt`): boot header v2, size equals the partition, AVB footer verifies, kernel/dtb/dtbo identical to `prebuilt/`, the ramdisk is identical to the device tree, every library of the decrypt stack (qseecomd, keymaster 4.1, gatekeeper) resolves inside the ramdisk. The time limit was exercised on a PC against stand-ins.

### Limits
- Targets PixelOS-style FBE (fscrypt v2, inline crypto, wrapped keys). Data encrypted by stock MIUI will not decrypt.
- The recovery uses Android 12-era decryption code; reading keys written by Android 16 is unverified.
- `panic=0` is on the kernel command line for now: a kernel panic freezes the screen instead of rebooting.

Kernel source: PixelOS-Devices/android_kernel_xiaomi_sm6150 @ f7d0768 (GPL-2.0); config and build script are in `kernel/`. The OrangeFox change is `patches/0001-toco-startup-hardening.patch`. See `NOTICE.md` for the provenance of the proprietary vendor binaries.
