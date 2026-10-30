**`r10`, the final release: `r9` with MTP built in. On the phone it was built for it works, MTP included (the owner's report on 30 October: one phone, nothing counted over a long series of boots).** OrangeFox R12.0 (unofficial, `fox_12.1` build system) for the Xiaomi Mi Note 10 Lite (toco), aimed at PixelOS (Android 16) `/data`.

### What is new: MTP
MTP lets a PC show the phone's internal storage as a media device (on Windows: under "This PC") and copy files without adb. `r5` to `r9` had it switched off: it was suspected of the kernel panics, and a log line (`[MTP] Failed to start usb driver!`) made it look broken. The panics were the vendor haptics driver (`r9` keeps it from loading, see `docs/TROUBLESHOOTING.md`), and from reading the recovery's code that line is expected once on the legacy path (the first open of `/dev/mtp_usb` is held while the server opens it again, then it retries; not observed on the phone). So MTP is back, the way the official OrangeFox trees for the same SoC family have it:
- The USB gadget file is the one of the official `sweet` and `miatoll` trees: the kernel's legacy `mtp.gs0` function (`/dev/mtp_usb`). The PixelOS kernel has that driver.
- **MTP starts after the password.** OrangeFox starts MTP at boot only when `/data` is not encrypted or already decrypted; here the user's keys come with the password, so nothing started it. `patches/0002-toco-mtp-after-decrypt.patch` starts it once the password has been accepted, with the same crash guard as at boot (if the recovery dies while starting MTP, the next start leaves MTP off).
- Starting MTP re-programs the USB gadget (`sys.usb.config` none, then `mtp,adb`): adb disconnects for a few seconds and comes back, and the PC enumerates the phone again. Wait about 15 seconds after the password.

### Changes since `r9`
- MTP built in; `FOX_EXCLUDE_MTP=true` builds the `r5` to `r9` behaviour. Patch 0002 (see above).
- `tools/toco-logs.bat` and `tools/toco-capture.sh` also write `usb.txt`: UDC state, gadget id and links, `/dev/mtp_usb`, `sys.usb.*`, the MTP lines of `recovery.log`.
- `tools/verify_image.sh` checks MTP: the library, its dependencies, the patch (by its log string), the USB gadget file and the kernel's MTP driver. The first full build of `r10` failed that check (the patch had been wrapped in `#ifdef TW_HAS_MTP`, which the GUI library is built without, so the code was missing): fixed and rebuilt before these files were made.
- Nothing else: kernel, dtb, dtbo and kernel command line (the same `initcall_blacklist=drv260x_driver_init` as `r9`) are byte-identical to `r9`'s for both variants, and the ramdisks of both variants differ from `r9`'s in `system/bin/recovery` and in the build date and id files only (checked by unpacking both releases and comparing file by file).

### Files
- `OrangeFox-R12.0-Unofficial-toco-r10.img` / `.zip` - full build (decryption stack, MTP)
- `OrangeFox-R12.0_nocrypt-Unofficial-toco-r10.img` / `.zip` - no decryption stack (MTP is built in but shows no files: `/data` stays encrypted)

```
e4b57059a12c7cfc7acb76e293d5eff7453b195eb5c2dca89fe7fda258218f0b  OrangeFox-R12.0-Unofficial-toco-r10.img
64fbc0468c034b2240a31ad0d1494b11eb3496761f34d776e31cb71a5f6857d4  OrangeFox-R12.0_nocrypt-Unofficial-toco-r10.img
d0de135c7010d7a67930c9c68bdc2fde81d727cc0f9b10b2860b025502393f45  OrangeFox-R12.0-Unofficial-toco-r10.zip
efa430b234d8e4be8aaa2b314daf1868381e27601f5d8769667fe2976310986e  OrangeFox-R12.0_nocrypt-Unofficial-toco-r10.zip
```
Each `.img` is exactly 128 MiB (the recovery partition size) with an AVB footer made with the AOSP test key. Static checks (`tools/verify_image.sh`): 33 of 33 for the full image, 29 of 29 for `-nocrypt` (`r9`: 28 and 24; the new checks are the MTP ones). Both ramdisks are LZMA-compressed (18,222,733 bytes for the full image, 16,063,007 for `-nocrypt`).

### Use it
`fastboot boot` does not change anything on the phone:
```
fastboot boot OrangeFox-R12.0-Unofficial-toco-r10.img
```
1. Try it with `fastboot boot` first; flash it to `recovery` only after a boot worked and you want it as your recovery. `r9` was never booted on its own: `r10` contains it.
2. Type the password, then wait about 15 seconds. The PC lists the phone with "Internal Storage" (Windows: "This PC"); copy your files out.
3. If the phone does not show up: Mount, switch MTP off and on; another cable or port. `adb shell` should still work. Then run `tools/toco-logs.bat` and send the zip: `usb.txt` and `recovery.log` show how far the USB side got.

Do not use Format Data or Wipe: while `/data` is not decrypted they would destroy it.

### Limits
- Tested on one phone only (the one it was built for); how reliably it boots was not counted over a long series of boots. `adb pull`/`adb push` stay available next to MTP; names that Windows cannot hold (`Android/data` has some) fail over MTP too, and `tools/toco-pull-sdcard.bat` skips them.
- Targets PixelOS-style FBE (fscrypt v2, inline crypto, wrapped keys). Data encrypted by stock MIUI will not decrypt.
- The recovery uses Android 12-era decryption code; reading keys written by Android 16 is unverified.
- The static checks of the images show that they are what the tree says; that they work is the owner's report.

Kernel: `prebuilt/Image-pixelos.gz` is PixelOS's published GPL-2.0 kernel (source: PixelOS-Devices/android_kernel_xiaomi_sm6150); the own build is the same repository at f7d0768 with the config and build script in `kernel/`. The OrangeFox changes are `patches/0001-toco-startup-hardening.patch` and `patches/0002-toco-mtp-after-decrypt.patch`. See `NOTICE.md` for provenance, including the proprietary vendor binaries.
