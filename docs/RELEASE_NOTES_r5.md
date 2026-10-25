**Pre-release `r5` for testing. `/data` decryption is not known to work yet, and the recovery is not known to be stable.** OrangeFox R12.0 (unofficial, `fox_12.1` build system) for the Xiaomi Mi Note 10 Lite (toco), aimed at PixelOS (Android 16) `/data`.

### What the logs from a real phone showed
* **The decryption chain works up to `keystore2`.** In the `r4` full image `qseecomd` (RPMB and SSD listeners), the Keymaster 4.1 HAL (its trusted app answers: "TA API 4, TA 4.556") and the gatekeeper HAL all start and register. `keystore2` aborts at start-up (`Check failed: serviceManager.get() Failed to get ServiceManager`) and crash-loops, so the recovery's key retrieval waits until its 90 s limit. Cause: the ramdisk had no framework VINTF manifest (`system/etc/vintf/manifest.xml`), so `android.hidl.manager@1.2` was declared nowhere and libhidl refused to hand out the HIDL service manager. The official `sweet`/`miatoll` OrangeFox trees ship that file.
* **Random kernel panics (heap corruption).** `pstore` shows panics in `kmalloc-512` allocations, at 24 s in one boot and at **2.67 s** in another (inside the display driver's initialisation, before any USB, `adbd`, MTP or user space exists). About every second boot is affected, with or without the decryption stack. Who corrupts the memory is not known; it is not MTP. See `docs/TROUBLESHOOTING.md`.

### Files
Release (the same kernel as `r3`):
- `OrangeFox-R12.0-Unofficial-toco-r5.img` / `.zip` - full build (decryption stack)
- `OrangeFox-R12.0_nocrypt-Unofficial-toco-r5.img` / `.zip` - no decryption stack

Debug (slower; for finding the memory corruption, not for daily use):
- `OrangeFox-R12.0_nocrypt-Unofficial-toco-r5-debug.img` / `.zip`
- `OrangeFox-R12.0-Unofficial-toco-r5-debug.img` / `.zip`

The debug images carry a kernel built with KASAN (in the directories most likely to matter: core, mm, fs, net, USB, block/UFS, input, DRM/display, DMA-BUF, SoC/power/misc), SLUB debugging and page poisoning (`kernel/debug.fragment`, `kernel/debug-kernel.patch`); the command line adds `kasan_multi_shot slub_debug=FZPU nokaslr` (page poisoning is on by default in that kernel). MTP is kept, everything else is as in the release image. With them, a write into freed or out-of-bounds memory is reported with the place, the bytes and the allocation/free history (`BUG: KASAN: ...`, `BUG kmalloc-512: Poison overwritten`, `pagealloc: memory corruption`), and the boot continues so that `toco-logs.bat` can fetch the report over `adb`.

```
4ccdeaf61ad8f070452cf7b5b6fd6e34a7f0fe2a1b23b362a54272de24bd1bce  OrangeFox-R12.0-Unofficial-toco-r5.img
5d4a3835c6bb72e9641ef184114bb0732238585ba3370688f866b104308a3b85  OrangeFox-R12.0-Unofficial-toco-r5.zip
2c1bc4f7cb424f61a23b5ec2da5fe07780e40c9a71fe22e28f9a9511ae3e0ae9  OrangeFox-R12.0_nocrypt-Unofficial-toco-r5.img
913a0a65b1ca0b79a4600776b62f286fd9f11c98b0ae5217130f2e8efb61e32c  OrangeFox-R12.0_nocrypt-Unofficial-toco-r5.zip
47867b19d804ebe9933d836fb558b1358857a92f6f2462f4bfba203c11a5b1ed  OrangeFox-R12.0-Unofficial-toco-r5-debug.img
90acf0663c8607a1ef1100ebb812058b98f5ad01e7c96303b909fc1e9f4a3511  OrangeFox-R12.0-Unofficial-toco-r5-debug.zip
9b773bca267b212534835a747773dc13094f1919f79981f5e679d263ab7b9aa3  OrangeFox-R12.0_nocrypt-Unofficial-toco-r5-debug.img
a04eaa7377745a8cac208d483c777911ae8921a6e98efd0f9da7e30ee4d5297a  OrangeFox-R12.0_nocrypt-Unofficial-toco-r5-debug.zip
```
Each `.img` is exactly 128 MiB (the recovery partition size) with an AVB footer made with the AOSP test key. The debug kernel (`Image.gz`, 17.4 MB) is not committed; `kernel/build_kernel.sh` rebuilds it.

### Changes since `r3`
- **Framework VINTF manifest added** (`recovery/root/system/etc/vintf/manifest.xml`): the fix for the `keystore2` crash loop. This is the first build in which the recovery can actually ask `keystore2` to decrypt the metadata key, so the next report will show how far that gets.
- **No MTP** (`TW_EXCLUDE_MTP`): the recovery no longer re-programs the USB gadget at about 13 s. It was suspected of the panics and is not their cause, but MTP never worked on this device anyway ("Failed to start usb driver"). Use `adb pull`/`adb push` to copy files. (The missing `AID_MEDIA_RW` include that this exposed in `partitionmanager.cpp` is added in `patches/0001-toco-startup-hardening.patch`.)
- `panic=0` stays on the command line: a kernel panic freezes the screen instead of restarting the phone, which tells it apart from other failures and keeps the panic log in `pstore`.
- The decrypt diagnostics (`fox-decrypt-diag.log`, also appended to `/tmp/recovery.log`) report the recovery's own decrypt steps and keystore2's log lines in separate sections.
- `tools/toco-logs.bat` / `tools/toco-capture.sh` also fetch `/proc/version` and write `memory-errors.txt` (the kernel's memory-corruption, oops and panic lines from the live log and `pstore`). The `.bat` is kept in Windows (CRLF) line endings.
- `scripts/build_fox.sh [full|nocrypt] [debug]` builds the images (`debug` uses the kernel in `prebuilt-debug/`).

### Try it
Boot it first and keep your current recovery:
```
fastboot boot OrangeFox-R12.0-Unofficial-toco-r5.img
```
Expect one boot in two to freeze (hold Power to restart, hold Volume-Down to land in fastboot, boot again). When one comes up, note what the menu shows (internal storage visible, password prompt, error) and run `tools/toco-logs.bat` (Windows) / `tools/toco-capture.sh` (macOS, Linux). If a boot froze, boot again and run the tool: `pstore.txt` in the result holds the console of the frozen boot.

Do not use Format Data or Wipe: while `/data` is not decrypted they would destroy it. The recovery's key code keeps upgraded key blobs in RAM and does not write to `/metadata`; `/data` is mounted with `encrypt: 0 format: 0`.

### Limits
- Targets PixelOS-style FBE (fscrypt v2, inline crypto, wrapped keys). Data encrypted by stock MIUI will not decrypt.
- The recovery uses Android 12-era decryption code; reading keys written by Android 16 is unverified.
- Static checks only for the images (`tools/verify_image.sh`: 25/25 full, 21/21 nocrypt; the same for the debug images).

Kernel source: PixelOS-Devices/android_kernel_xiaomi_sm6150 @ f7d0768 (GPL-2.0); config and build script are in `kernel/`. The OrangeFox change is `patches/0001-toco-startup-hardening.patch`. See `NOTICE.md` for the provenance of the proprietary vendor binaries.
