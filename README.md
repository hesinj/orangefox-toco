# OrangeFox for the Xiaomi Mi Note 10 Lite (toco), PixelOS / Android 16

Unofficial OrangeFox (`fox_12.1` build system) recovery and device tree for the Mi Note 10 Lite (Snapdragon 730G, SM6150 / `sdmmagpie`).
It opens the encrypted `/data` of **PixelOS / Android 16** (the metadata layer by itself during boot, your password in the menu)
and lets you copy your files off the phone over **MTP** (the PC shows the storage as a media device) or **adb**.

> **Status: `r10` is the final release.** On the phone it was built for, it boots, decrypts `/data` and copies files over MTP and over
> adb (the owner's report: one phone; nothing was counted over a long series of boots). The earlier internal builds, `r2` to `r8`, froze or
> panicked in about half of the boots. The cause was found afterwards, from many logs: on that phone the kernel's vendor haptics
> driver (`drv260x`) corrupts kernel memory when the I2C bus it sits on is dead. `r9` and `r10` keep that driver from loading
> ([`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md); the whole repair story, which also brought the phone's Android back without a
> factory reset, is in [repairing_my_phone_with_claude](https://github.com/hesinj/repairing_my_phone_with_claude)).
> The author has no access to the device: everything here comes from logs and reports of its owner.
> Back up first, use `fastboot boot` before flashing, and keep your current recovery.

## Downloads
The built recoveries and `SHA256SUMS` are attached to the **Releases** page, not committed: the image is
128 MiB, over GitHub's 100 MB file limit.

| File | What |
|---|---|
| `OrangeFox-R12.0-Unofficial-toco-r10.img` / `.zip` | **the recovery**: PixelOS's release kernel, decryption stack, framework VINTF manifest, MTP, LZMA ramdisk, haptics driver not loaded |
| `OrangeFox-R12.0_nocrypt-Unofficial-toco-r10.img` / `.zip` | the same without any decryption stack, only to tell kernel/display/touch problems from decryption problems (`/data` stays encrypted, so MTP shows no files) |

**`r10` is the only published release.** The builds before it, `r1` to `r9`, were internal test builds: only the phone's owner tried them
(the author has no access to the device), they were never released, and Releases has nothing of them to download. They live on in the
history of this repository and in `docs/TROUBLESHOOTING.md`, which is the log of those builds; the files `docs/RELEASE_NOTES_r3.md` to
`docs/RELEASE_NOTES_r9.md` are the notes that went with some of them, and only `docs/RELEASE_NOTES_r10.md` belongs to the release.
(`r9` is `r10` built with `FOX_EXCLUDE_MTP=true`, i.e. without MTP; `r8` is `r9` without the `initcall_blacklist` parameter.)

## Use it

1. **Try it without installing** (this writes nothing to the phone). Use the full image, not `nocrypt`, for your files:
   ```sh
   fastboot boot OrangeFox-R12.0-Unofficial-toco-r10.img
   ```
2. Type your password. OrangeFox decrypts `/data` and starts MTP; wait about 15 seconds (adb drops and comes back while the USB gadget is
   re-programmed). The PC then lists the phone with "Internal Storage" (Windows: "This PC"). `adb pull` and `adb push` work as well.
3. **Install it** only after a boot worked, and only if you want it as your recovery:
   ```sh
   fastboot flash recovery OrangeFox-R12.0-Unofficial-toco-r10.img
   fastboot flash vbmeta --disable-verity --disable-verification vbmeta.img   # your own vbmeta.img
   ```
4. **Never use Format Data or Wipe** while `/data` is not decrypted: they would destroy it.

What is inside: PixelOS's own release kernel, byte for byte; decryption of PixelOS's `/data` (fscrypt v2, metadata encryption, hardware-wrapped
keys), bounded to 90 s so that the logo never hangs; MTP, started after the password; adb; and the kernel parameter
`initcall_blacklist=drv260x_driver_init`. The recovery does not use the vibration chip, so nothing is lost. If the phone's Android itself
does not boot for the same reason, see the repair story linked above.

## Other ROMs and older Android versions

By design, booting the recovery does not depend on the installed ROM: it brings its own kernel and ramdisk, so it should start and serve
adb whatever ROM is installed (on a toco with an unlocked bootloader), and the logical partitions (`system`, `system_ext`, `product`,
`vendor`, `odm`) are mounted read-only from `super`, as ext4 or erofs. **Only PixelOS 16 was tried**, so this is the design, not a test.

What does depend on the ROM is **opening `/data`**, and with it everything that needs the files (MTP showing the storage, `adb pull` of
`/sdcard`, backups of data). The recovery is set up for exactly the encryption that PixelOS 16 uses: fscrypt v2
(`TW_USE_FSCRYPT_POLICY := 2`), metadata encryption with a hardware-wrapped key (`wrappedkey_v0`,
`keydirectory=/metadata/vold/metadata_encryption`), `inlinecrypt` and f2fs compression, written in
`recovery/root/system/etc/twrp.flags` and `recovery.fstab`. Its decryption services (`qseecomd`, Keymaster 4.1, gatekeeper) come from the MIUI
V13.0.4.0.SFNMIXM vendor.

* A ROM that formatted `/data` with the same setup should work the same; this was not tried.
* **Legacy `fileencryption=ice` (stock MIUI) and other older formats are not supported.** It is the format that matters, not the Android
  version number: a lower Android version may well use an older format, and then the answer is no.
* Another firmware than V13.0.4 under the ROM was not tried either.
* `/data` that is not encrypted at all was not tried: the full build looks for PixelOS's metadata key.
* If it cannot decrypt, the symptom is a rejected password or an internal storage of 0 MB (and MTP showing no files). The recovery formats
  nothing by itself, so a failed decryption leaves the data as it was. **Do not use Format Data or Wipe**: they destroy it. Use the ROM's
  own recovery instead, or adapt the tree (`skills/orangefox-fbe-recovery-port` explains how a tree like this is made for another ROM's encryption).

## Using this repository
The repo root *is* the device tree. Clone it into an OrangeFox 12.1 tree:

```sh
git clone https://github.com/hesinj/orangefox-toco ~/fox_12.1/device/xiaomi/toco
```

| Path | What it is |
|---|---|
| `BoardConfig.mk`, `device.mk`, `fox_toco.mk`, `twrp_toco.mk`, `vendorsetup.sh` | the device tree |
| `prebuilt/` | `Image-pixelos.gz` (PixelOS's release kernel, the default), `Image.gz` (the same source built here), `dtb`, `dtbo.img` |
| `recovery/root/` | ramdisk additions: fstab/flags, init scripts, ueventd rules, vintf manifest, decrypt binaries and libraries, `fox_decrypt_diag.sh` |
| `patches/0001-toco-startup-hardening.patch`, `patches/0002-toco-mtp-after-decrypt.patch` | changes to OrangeFox's `bootable/recovery` (see "Build"): the time-limited decrypt; MTP started after the data password |
| `kernel/` | kernel source commit, resolved `.config`, build script, and `debug.fragment` + `debug-kernel.patch` for the KASAN/SLUB debug kernel |
| `tools/verify_image.sh`, `tools/verify_ramdisk.py` | static checks of a built image and of the decrypt stack's library dependencies |
| `tools/toco-logs.bat`, `tools/toco-capture.sh` | collect logs from the phone over adb (Windows / macOS+Linux), including pstore, a summary of kernel memory errors and the USB/MTP state (`usb.txt`) |
| `tools/toco-pull-sdcard.bat` | Windows: copy the phone's internal storage to the PC (files as a tar stream, folders one by one), skipping `Android\data`, so that one name Windows cannot create does not stop the whole `adb pull` |
| `tools/toco-probe.sh`, `tools/toco-probe.bat` | start the decryption services by hand, one by one, from the `-nocrypt` image and report what each does |
| `scripts/` | helpers used while building (`build_fox.sh`, `drop_objs.py`, `inventory.py`) |
| `docs/TROUBLESHOOTING.md` | what was seen on the device (the log of the internal builds `r1` to `r9`), how to read the log, what each outcome means |
| `docs/BUILD_NOTES.md` | how it was built and what went wrong |
| `NOTICE.md` | provenance and licensing of the kernel and the proprietary blobs |

## Device layout

| | |
|---|---|
| Partitioning | A-only, dedicated `recovery` partition (128 MiB), dynamic partitions (`super`, 9126805504 B) |
| Boot image | header v2, base `0x0`, kernel offset `0x8000`, ramdisk offset `0x1000000`, dtb offset `0x1f00000`, page 4096 |
| Display | 1080x2340, backlight `/sys/class/backlight/panel0-backlight/brightness`, 2-2047 |
| UFS | `1d84000.ufshc`; USB `a600000.dwc3` |

Partition sizes and boot parameters come from the PixelOS device tree
(`PixelOS-Devices/android_device_xiaomi_toco`, `sixteen-qpr2`); display/UFS/USB values were
checked against the kernel device tree.

## Why a custom kernel

PixelOS (Android 16) formats `/data` with this fstab entry:

```
fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized+wrappedkey_v0
metadata_encryption=aes-256-xts:wrappedkey_v0
keydirectory=/metadata/vold/metadata_encryption
fscompress          (f2fs compress_extension=apk,apex,so)
```

That needs fscrypt **v2** policies, blk-crypto inline encryption, hardware-wrapped keys and
f2fs compression in the kernel. Xiaomi's stock `toco-q-oss` kernel (4.14.117) has none of them
(no `FS_IOC_ADD_ENCRYPTION_KEY`, `# CONFIG_PFK_WRAPPED_KEY_SUPPORTED is not set`), so a recovery
built on it cannot read PixelOS data. This tree therefore ships the kernel PixelOS ships:

* **default: the kernel of the PixelOS release itself** (`prebuilt/Image-pixelos.gz`), taken unchanged from the
  `boot-toco_20260609_1626.img` of PixelOS's SourceForge release (`Linux version 4.14.356-openela-rc1-VantomKernel
  (ci@PixelOS-CI) ... clang version 21.0.0, LLD 21.0.0 ... #1 SMP PREEMPT Tue Jun 9 18:45:28 CEST 2026`,
  sha256 `abf7b66fd6a3529003f01130c3fa367a92cb1f04e765f08139ed75917ebe1752`). It is the kernel that runs on the phone
  every day. Source: `https://github.com/PixelOS-Devices/android_kernel_xiaomi_sm6150` (branches `sixteen*`), see `NOTICE.md`.
* `FOX_OWN_KERNEL=true`: the same source built here (`prebuilt/Image.gz`): branch `sixteen-qpr2`, commit
  `f7d0768273eab39b52664efd2cfddcfdc9359e8e` (4.14.356-openela-rc1-VantomKernel), `toco_defconfig` (resolved config:
  `kernel/toco_defconfig.resolved.config`), toolchain AOSP clang 12.0.5 (r416183b) + gcc 4.9 binutils
  (`kernel/build_kernel.sh`). The internal builds `r2` to `r6` used this one and panicked in about half of the boots (see
  `docs/TROUBLESHOOTING.md`, "Fifth report"): both binaries are the same source and configuration (their kernel messages
  match except for 7 of about 14000 strings); they differ in compiler and linker.
* `prebuilt/dtb` and `prebuilt/dtbo.img` are byte-identical to the ones in PixelOS's images (the dtbo is
  built from `toco-sdmmagpie-overlay.dtbo` (TOCO, board-id 0x2c) with `mkdtboimg`)

**Trade-off:** one recovery has one kernel. Because it matches PixelOS, data encrypted by
**stock MIUI** (legacy `fileencryption=ice`, v1 policies) is *not* the target of this build.

## Decryption stack

`qseecomd`, `android.hardware.keymaster@4.1-service-qti` and
`android.hardware.gatekeeper@1.0-service-qti` plus their libraries are taken from toco's stock
MIUI V13.0.4.0.SFNMIXM vendor (via the blob repo PixelOS uses,
`gitlab.com/NoPrincessHere/proprietary_vendor_xiaomi_sm6150-common`, branch `sixteen`).
The dependency set was computed from the ELF `DT_NEEDED` entries plus the libraries
`qseecomd` loads with `dlopen`. OrangeFox picks the keymaster version at runtime from the
installed vendor's VINTF manifest. Start-up order is `recovery -> prepdecrypt.sh -> qseecomd ->
Keymaster HAL (+ gatekeeper)`, with `keystore2` between the recovery process and the HAL.

What `qseecomd` needs, from disassembling it: it starts ten listeners (`librpmb`, `libssd`, `libsecureui`,
`libdrmtime`, `libdrmfs` twice, `libqisl`, `libspl`, `libGPreqcancel`, `libops`). Only the first two,
RPMB and SSD, are mandatory: they run as root before it drops to uid 1000, and if either fails it exits
without ever setting `vendor.sys.listeners.registered`, so the Keymaster HAL is never started. The other eight are
started with their return values ignored, so a missing `libsecureui`, `libspl` or `libops` (and the
display libraries those pull in) is logged and skipped. The official `sweet` and `miatoll` trees ship
`libops` and `libsecureui` with their dependencies; this tree does not.
`libtime_genoff.so` is included (needed by `libdrmtime.so`).

## Verification

`tools/verify_image.sh <img> <label> <yes|no> [release|own|debug]` checks a built image. For `r10` it reports 33 of 33 checks
passing for the full image and 29 of 29 for `-nocrypt` (`r9`: 28 and 24; `r5`: 25 and 21):

* boot header v2; cmdline as in `BoardConfig.mk`; kernel/DTB/DTBO byte-identical to `prebuilt/` (`prebuilt-debug/` for debug)
* image is exactly 134217728 B (the recovery partition size) with an AVB footer that verifies
  (SHA256_RSA4096, rollback index 1, AOSP test key)
* every file of `recovery/root` is in the ramdisk byte for byte and nothing else is in `vendor/lib64`
  (this check exists because earlier images carried a stale `libops.so`)
* the framework VINTF manifest is present and declares `android.hidl.manager@1.2` (without it `keystore2` aborts)
* the recovery binary links the MTP library, `libtwrpmtp-ffs.so` and everything it needs are in the ramdisk, the binary has the
  MTP start after the password (patch 0002), the USB gadget file has the `mtp.gs0` function and the `mtp,adb` configuration and the
  kernel has the MTP function driver (`EXPECT_MTP=no` checks a `FOX_EXCLUDE_MTP` image for no MTP instead); the binary contains the
  time-limited decrypt (full); the generated decrypt `init` files are there (full) or absent (`nocrypt`)
* every `DT_NEEDED` and `dlopen`'d library of `qseecomd`, keymaster 4.1 and gatekeeper
  resolves inside the ramdisk (`verify_ramdisk.py`)

The time-limit logic was run on a PC against stand-ins for a decrypt call that returns, blocks forever
and fails at once.

These checks are static: they show that the image is what the tree says it is, not that it works. That `r10` boots, decrypts `/data` and
transfers files on the phone is the owner's report (see the top).

## Build

```sh
./orangefox_sync.sh --branch 12.1 --path ~/fox_12.1      # from https://gitlab.com/OrangeFox/sync
# put this tree at ~/fox_12.1/device/xiaomi/toco
cd ~/fox_12.1/bootable/recovery
git apply ../../device/xiaomi/toco/patches/0001-toco-startup-hardening.patch   # base 4f00a3d, fox_12.1
git apply ../../device/xiaomi/toco/patches/0002-toco-mtp-after-decrypt.patch    # on top of 0001 (they touch different files)
cd ~/fox_12.1
export ALLOW_MISSING_DEPENDENCIES=true LC_ALL=C FOX_BUILD_DEVICE=toco
export FOX_LZMA_RAMDISK=true        # LZMA ramdisk (18 MB instead of 28.6 MB), as in r8 to r10
# export FOX_VARIANT=nocrypt        # for the variant without decryption
# export FOX_EXCLUDE_MTP=true       # build without MTP, as r5 to r9 were
source build/envsetup.sh
lunch twrp_toco-eng
rm -rf out/target/product/toco/{root,recovery,fake_packages}   # do not carry stale ramdisk files over from earlier builds
mka adbd recoveryimage
```

`scripts/build_fox.sh [full|nocrypt] [debug]` does this (it sets `FOX_LZMA_RAMDISK=true` unless you give it another value;
without it the ramdisk is gzip, as in `r2` to `r7`). `debug` selects the KASAN kernel from `prebuilt-debug/`
(not committed, 24 MB: build it with `kernel/build_kernel.sh`, see `kernel/debug.fragment`).

## MTP

MTP lets a PC show the phone's internal storage as a media device (on Windows: under "This PC"), without adb. It is built in since `r10`
and works on the phone it was built for (the owner's report). What the tree does:

* The USB gadget file `recovery/root/init.recovery.usb.rc` is the one of the official OrangeFox trees for the same SoC family (sweet,
  miatoll): the kernel's legacy `mtp.gs0` function, which gives the recovery the device `/dev/mtp_usb`. The PixelOS kernel has that
  driver (`f_mtp`) and FunctionFS.
* OrangeFox starts MTP at boot only when `/data` is not encrypted or already decrypted. Here `/data` is still encrypted at that
  moment, so `patches/0002-toco-mtp-after-decrypt.patch` starts it after the password has been accepted (the same crash guard as at
  boot: if the recovery dies while starting MTP, the next start leaves MTP off). Starting MTP re-programs the USB gadget
  (`sys.usb.config` none, then `mtp,adb`): adb disconnects for a few seconds and comes back, and Windows enumerates the phone again.
* If it does not show up: Mount, then the MTP switch (off and on again); unplug and plug the cable. `adb` still works, and
  `tools/toco-logs.bat` also writes `usb.txt` (UDC state, gadget files, `/dev/mtp_usb`, the MTP lines of `recovery.log`).
* File names that Windows cannot hold (`Android/data` has some) fail over MTP just as over `adb pull`:
  `tools/toco-pull-sdcard.bat` skips them.
* MTP was once suspected of the kernel panics and was switched off for that reason in `r5` to `r9`; the panics were the haptics
  driver (see above), not MTP. `FOX_EXCLUDE_MTP=true` builds that old behaviour (no MTP, no gadget switch).

## Limitations / things to know

* **Tested on one phone**: the one it was built for (unlocked bootloader, PixelOS 16.2 build 20260609_1626). Other units, other
  PixelOS builds and other ROMs were not tried, and how reliably it boots was not counted over a long series of boots: the failures of
  `r2` to `r8` came about every other boot, and the cause that was found is gone in `r9` and `r10`, but only the owner's reports show how
  it behaves. `adb pull`/`adb push` stay available next to MTP. A debug build (`scripts/build_fox.sh full debug`; none is
  published) runs with `panic=0`, so that a kernel panic freezes the screen and can be read back from pstore after a forced restart.
* **No automatic writes to `boot`/`system`.** `OF_PATCH_AVB20` is off and
  `OF_DONT_PATCH_ON_FRESH_INSTALLATION` is on. With `OF_PATCH_AVB20`, OrangeFox hex-patches the
  real `boot` partition's AVB footer before every reboot from the recovery, and the zip installer's
  first-run path repacks the boot image. The first internal build (`r1`) had that enabled by mistake.
  OrangeFox's own patching features still write to flash if you explicitly use them.
* While `/data` is not decrypted nothing in internal storage is readable over `adb` or MTP, and
  Format Data would destroy it.
* Targets PixelOS-style FBE v2 + wrapped keys. Stock MIUI (`ice`) data will not decrypt; see "Other ROMs and older Android versions".
* Haptics are disabled (`TW_NO_HAPTICS`); there is no microSD slot entry.
* **A dead I2C bus can corrupt kernel memory on this phone.** The kernel's vendor haptics driver (`drv260x`, I2C `3-005a`)
  double-frees its memory when its probe fails, then writes the vibration firmware into the freed object. On a unit whose I2C
  bus 3 is dead (`Bus arbitration lost, clock line undriveable`, `probe of 3-005a failed with error -71`) that makes recovery boots
  die with a black screen and keeps Android from booting (`bootstrap-apexd-failed`, `init_user0_failed`), with no sign of a
  hardware fault. Builds from `r9` on carry `initcall_blacklist=drv260x_driver_init` (the recovery does not use that chip); for
  the installed ROM add the same parameter to its boot image (`tools/make-diag-boot.sh`). Details and the proof:
  `docs/TROUBLESHOOTING.md`, "The writer is found"; the repair of the phone's Android:
  [repairing_my_phone_with_claude](https://github.com/hesinj/repairing_my_phone_with_claude).
* `TW_MAX_BRIGHTNESS` (2047) comes from the panel DT `bl-max-level`; the sysfs `max_brightness`
  was not checked on a device.
* The partition list in `twrp.flags` (modem, bluetooth, dsp, efs, persist) follows the common
  Xiaomi SM6150 layout; entries missing on a given unit only produce mount warnings.
