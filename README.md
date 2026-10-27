# OrangeFox device tree: Xiaomi Mi Note 10 Lite (toco)

Unofficial OrangeFox (`fox_12.1` build system) device tree for the Mi Note 10 Lite
(Snapdragon 730G, SM6150 / `sdmmagpie`), targeting **PixelOS / Android 16** userdata.

> **Status: `r9` is `r8` plus one kernel parameter, `initcall_blacklist=drv260x_driver_init`, and has not been booted yet.
> `r8` booted on the phone, decrypted `/data` (the metadata layer by itself during boot, then the user's password in the
> menu) and let the user copy the internal storage with `adb pull`. That is one reported session.** Builds `r2` to `r7`
> froze or panicked in about half of the boots.
>
> The author has no access to the device and works from logs the user sends back. What they showed: the freezes were
> kernel heap corruption (the first eight bytes of a *free* kernel object overwritten with high-entropy data, found by the
> next allocation of that object, anywhere from 1.1 s to 24 s after the kernel starts). **The writer was found afterwards:
> the kernel's vendor haptics driver (`drv260x`, I2C `3-005a`).** On the reporting phone the I2C bus 3 has stopped answering;
> the driver's probe fails, double-frees its memory and later writes its vibration firmware into the freed object. The
> recovery does not use that chip, so `r9` keeps the driver from loading. The same parameter in the boot image of the
> installed ROM made Android boot again on that phone, without a factory reset. So taking "PixelOS's own `recovery.img` always
> boots" as a sign of healthy hardware was wrong: the corruption lands in a random freed object, and that recovery was not hit in
> the boots that were tried. Whether `r8`'s other changes (PixelOS's release kernel binary, an LZMA-compressed ramdisk, none of
> `r7`'s extra precautions) changed anything is not known.
>
> See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).
> Back up first, use `fastboot boot` before flashing, and keep your current recovery.

## Downloads
The built recoveries and `SHA256SUMS` are attached to the **Releases** page, not committed: the image is
128 MiB, over GitHub's 100 MB file limit.

| File | What |
|---|---|
| `OrangeFox-R12.0-Unofficial-toco-r9.img` / `.zip` | full build: PixelOS's release kernel, decryption stack, framework VINTF manifest, no MTP, LZMA ramdisk, haptics driver not loaded |
| `OrangeFox-R12.0_nocrypt-Unofficial-toco-r9.img` / `.zip` | same without any decryption stack; use it to tell kernel/display/touch problems from decryption problems |
| `...-r5-debug.img` / `.zip` (full and `nocrypt`) | own kernel with KASAN + SLUB debugging, MTP kept, `panic=0`; slower, only for finding the memory corruption |

`r1` to `r8` are superseded (`r8` is `r9` without the `initcall_blacklist` parameter). `r1` also patched the real `boot` partition's AVB footer before reboots
(`OF_PATCH_AVB20`); `r2` removed that. Neither contained the later fixes.

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
| `patches/0001-toco-startup-hardening.patch` | change to OrangeFox's `bootable/recovery` (see "Build"); needed for the time-limited decrypt |
| `kernel/` | kernel source commit, resolved `.config`, build script, and `debug.fragment` + `debug-kernel.patch` for the KASAN/SLUB debug kernel |
| `tools/verify_image.sh`, `tools/verify_ramdisk.py` | static checks of a built image and of the decrypt stack's library dependencies |
| `tools/toco-logs.bat`, `tools/toco-capture.sh` | collect logs from the phone over adb (Windows / macOS+Linux), including pstore and a summary of kernel memory errors |
| `tools/toco-pull-sdcard.bat` | Windows: copy the phone's internal storage to the PC (files as a tar stream, folders one by one), skipping `Android\data`, so that one name Windows cannot create does not stop the whole `adb pull` |
| `tools/toco-probe.sh`, `tools/toco-probe.bat` | start the decryption services by hand, one by one, from the `-nocrypt` image and report what each does |
| `scripts/` | helpers used while building (`build_fox.sh`, `drop_objs.py`, `inventory.py`) |
| `docs/TROUBLESHOOTING.md` | what was seen on the device, how to read the log, what each outcome means |
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
  (`kernel/build_kernel.sh`). `r2` to `r6` used this one and panicked in about half of the boots (see
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

## Verification (static only)

`tools/verify_image.sh <img> <label> <yes|no> [release|own|debug]` checks a built image. For `r9` it reports 28 of 28 checks
passing for the full image and 24 of 24 for `-nocrypt` (`r5`: 25 and 21):

* boot header v2; cmdline as in `BoardConfig.mk`; kernel/DTB/DTBO byte-identical to `prebuilt/` (`prebuilt-debug/` for debug)
* image is exactly 134217728 B (the recovery partition size) with an AVB footer that verifies
  (SHA256_RSA4096, rollback index 1, AOSP test key)
* every file of `recovery/root` is in the ramdisk byte for byte and nothing else is in `vendor/lib64`
  (this check exists because earlier images carried a stale `libops.so`)
* the framework VINTF manifest is present and declares `android.hidl.manager@1.2` (without it `keystore2` aborts)
* the recovery binary has no MTP (release) and contains the time-limited decrypt (full); the generated decrypt `init`
  files are there (full) or absent (`nocrypt`)
* every `DT_NEEDED` and `dlopen`'d library of `qseecomd`, keymaster 4.1 and gatekeeper
  resolves inside the ramdisk (`verify_ramdisk.py`)

The time-limit logic was run on a PC against stand-ins for a decrypt call that returns, blocks forever
and fails at once.

None of this shows that `/data` decrypts on the device.

## Build

```sh
./orangefox_sync.sh --branch 12.1 --path ~/fox_12.1      # from https://gitlab.com/OrangeFox/sync
# put this tree at ~/fox_12.1/device/xiaomi/toco
cd ~/fox_12.1/bootable/recovery
git apply ../../device/xiaomi/toco/patches/0001-toco-startup-hardening.patch   # base 4f00a3d, fox_12.1
cd ~/fox_12.1
export ALLOW_MISSING_DEPENDENCIES=true LC_ALL=C FOX_BUILD_DEVICE=toco
export FOX_LZMA_RAMDISK=true        # LZMA ramdisk (18 MB instead of 28.6 MB), as in r8 and r9
# export FOX_VARIANT=nocrypt        # for the variant without decryption
source build/envsetup.sh
lunch twrp_toco-eng
rm -rf out/target/product/toco/{root,recovery,fake_packages}   # do not carry stale ramdisk files over from earlier builds
mka adbd recoveryimage
```

`scripts/build_fox.sh [full|nocrypt] [debug]` does this (it sets `FOX_LZMA_RAMDISK=true` unless you give it another value;
without it the ramdisk is gzip, as in `r2` to `r7`). `debug` selects the KASAN kernel from `prebuilt-debug/`
(not committed, 24 MB: build it with `kernel/build_kernel.sh`, see `kernel/debug.fragment`).

## Install

```sh
fastboot boot recovery.img                       # try it first
fastboot flash recovery recovery.img             # then, if it works
fastboot flash vbmeta --disable-verity --disable-verification vbmeta.img   # your own vbmeta.img
```

## Limitations / things to know

* Not tested on hardware that can decrypt (see top). The release builds have no MTP (use `adb pull`/`adb push`).
  The debug builds keep it and run with `panic=0`, so that a kernel panic freezes the screen and can be read back
  from pstore after a forced restart.
* **No automatic writes to `boot`/`system`.** `OF_PATCH_AVB20` is off and
  `OF_DONT_PATCH_ON_FRESH_INSTALLATION` is on. With `OF_PATCH_AVB20`, OrangeFox hex-patches the
  real `boot` partition's AVB footer before every reboot from the recovery, and the zip installer's
  first-run path repacks the boot image. `r1` had that enabled by mistake.
  OrangeFox's own patching features still write to flash if you explicitly use them.
* While `/data` is not decrypted nothing in internal storage is readable over `adb` or MTP, and
  Format Data would destroy it.
* Targets PixelOS-style FBE v2 + wrapped keys. Stock MIUI (`ice`) data will not decrypt.
* Haptics are disabled (`TW_NO_HAPTICS`); there is no microSD slot entry.
* **A dead I2C bus can corrupt kernel memory on this phone.** The kernel's vendor haptics driver (`drv260x`, I2C `3-005a`)
  double-frees its memory when its probe fails, then writes the vibration firmware into the freed object. On a unit whose I2C
  bus 3 is dead (`Bus arbitration lost, clock line undriveable`, `probe of 3-005a failed with error -71`) that makes recovery boots
  die with a black screen and keeps Android from booting (`bootstrap-apexd-failed`, `init_user0_failed`), with no sign of a
  hardware fault. Builds made after `r8` carry `initcall_blacklist=drv260x_driver_init` (the recovery does not use that chip); for
  the installed ROM add the same parameter to its boot image (`tools/make-diag-boot.sh`). Details and the proof:
  `docs/TROUBLESHOOTING.md`, "The writer is found".
* `TW_MAX_BRIGHTNESS` (2047) comes from the panel DT `bl-max-level`; the sysfs `max_brightness`
  was not checked on a device.
* The partition list in `twrp.flags` (modem, bluetooth, dsp, efs, persist) follows the common
  Xiaomi SM6150 layout; entries missing on a given unit only produce mount warnings.
