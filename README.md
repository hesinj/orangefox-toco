# OrangeFox device tree: Xiaomi Mi Note 10 Lite (toco)

Unofficial OrangeFox (`fox_12.1` build system) device tree for the Mi Note 10 Lite
(Snapdragon 730G, SM6150 / `sdmmagpie`), targeting **PixelOS / Android 16** userdata.

> **Status: built, not boot-tested.** This tree was produced without access to the device.
> It builds cleanly and the output was checked statically (see *Verification*), but nothing
> here has been booted on hardware. In particular **decryption of `/data` is unverified.**
> Back up first, boot with `fastboot boot` before flashing, and keep your current recovery.

## Downloads
The built recovery (`OrangeFox-R12.0-Unofficial-toco.img` and `.zip`) and `SHA256SUMS` are attached
to the **Releases** page, not committed: the image is 128 MiB, over GitHub's 100 MB file limit.

## Using this repository
The repo root *is* the device tree. Clone it into an OrangeFox 12.1 tree:

```sh
git clone https://github.com/hesinj/orangefox-toco ~/fox_12.1/device/xiaomi/toco
```

| Path | What it is |
|---|---|
| `BoardConfig.mk`, `device.mk`, `fox_toco.mk`, `twrp_toco.mk`, `vendorsetup.sh` | the device tree |
| `prebuilt/` | kernel `Image.gz`, `dtb`, `dtbo.img` (built from PixelOS's kernel source) |
| `recovery/root/` | ramdisk additions: fstab/flags, init scripts, vintf manifest, decrypt binaries and libraries |
| `kernel/` | kernel source commit, resolved `.config` and build script |
| `tools/verify_ramdisk.py` | static check of the decrypt stack's library dependencies |
| `scripts/` | helpers used while building (`build_fox.sh`, `drop_objs.py`, `inventory.py`) |
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

* source: `https://github.com/PixelOS-Devices/android_kernel_xiaomi_sm6150`, branch `sixteen-qpr2`,
  commit `f7d0768273eab39b52664efd2cfddcfdc9359e8e` (4.14.356-openela-rc1-VantomKernel)
* config: `toco_defconfig` (resolved config: `kernel/toco_defconfig.resolved.config`)
* toolchain: AOSP clang 12.0.5 (r416183b) + gcc 4.9 binutils, `Image.gz` + `dtbs`
* `prebuilt/dtbo.img` is built from `toco-sdmmagpie-overlay.dtbo` (TOCO, board-id 0x2c) with `mkdtboimg`

The kernel is GPL-2.0; the source above (plus the build script in `kernel/`) is the
corresponding source for `prebuilt/Image.gz`.

**Trade-off:** one recovery has one kernel. Because it matches PixelOS, data encrypted by
**stock MIUI** (legacy `fileencryption=ice`, v1 policies) is *not* the target of this build.

## Decryption stack

`qseecomd`, `android.hardware.keymaster@4.1-service-qti` and
`android.hardware.gatekeeper@1.0-service-qti` plus their libraries are taken from toco's stock
MIUI V13.0.4.0.SFNMIXM vendor (via the blob repo PixelOS uses,
`gitlab.com/NoPrincessHere/proprietary_vendor_xiaomi_sm6150-common`, branch `sixteen`).
The dependency set was computed from the ELF `DT_NEEDED` entries plus the libraries
`qseecomd` loads with `dlopen`. OrangeFox picks the keymaster version at runtime from the
installed vendor's VINTF manifest.

`libtime_genoff.so` is included (needed by `libdrmtime.so`). `libops.so` is deliberately
*not* included: `qseecomd` loads it optionally, and it would pull in the display stack
(`libdisplayconfig.qti`, `libdrm`); the working OrangeFox `sweet` tree omits it too.

## Verification (static only)

Checked on the built `OrangeFox-R12.0-Unofficial-toco.img`:

* boot header v2; kernel 14702951 B, DTB 397690 B @ `0x1f00000`, recovery DTBO 247270 B,
  cmdline as in `BoardConfig.mk`; kernel/DTB/DTBO are byte-identical to `prebuilt/`
* image is exactly 134217728 B (the recovery partition size) with an AVB footer
  (SHA256_RSA4096, rollback index 1, AOSP test key)
* every `DT_NEEDED` and `dlopen`'d library of `qseecomd`, keymaster 4.1 and gatekeeper
  resolves inside the ramdisk (`verify_ramdisk.py`, 43 ELF files)
* the ramdisk contains `twrp.flags` with the PixelOS `fileencryption=` / `metadata_encryption=`
  strings, the generated `init.recovery.qcom_decrypt*.rc`, and the VINTF declarations

None of this shows that the device boots or that `/data` decrypts.

## Build

```sh
./orangefox_sync.sh --branch 12.1 --path ~/fox_12.1      # from https://gitlab.com/OrangeFox/sync
# put this tree at ~/fox_12.1/device/xiaomi/toco
cd ~/fox_12.1
export ALLOW_MISSING_DEPENDENCIES=true LC_ALL=C FOX_BUILD_DEVICE=toco
source build/envsetup.sh
lunch twrp_toco-eng
mka adbd recoveryimage
```

## Install

```sh
fastboot boot recovery.img                       # try it first
fastboot flash recovery recovery.img             # then, if it works
fastboot flash vbmeta --disable-verity --disable-verification vbmeta.img   # your own vbmeta.img
```

## Limitations / things to know

* Not tested on hardware (see top).
* Targets PixelOS-style FBE v2 + wrapped keys. Stock MIUI (`ice`) data will not decrypt.
* Haptics are disabled (`TW_NO_HAPTICS`); there is no microSD slot entry.
* `TW_MAX_BRIGHTNESS` (2047) comes from the panel DT `bl-max-level`; the sysfs `max_brightness`
  was not checked on a device.
* The partition list in `twrp.flags` (modem, bluetooth, dsp, efs, persist) follows the common
  Xiaomi SM6150 layout; entries missing on a given unit only produce mount warnings.
