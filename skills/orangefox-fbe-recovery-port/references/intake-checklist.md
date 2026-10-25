# Intake checklist: the facts a recovery port needs

Every row says where the fact comes from and which line of the generated tree it ends up in. Collect them all before
generating the tree; a wrong guess here costs a boot test later. `[rom]` = output of `scripts/collect_device_facts.sh` on the
running ROM, `[boot]` = `scripts/unpack_and_inspect_boot.sh`, `[ref]` = an official OrangeFox/TWRP/Lineage tree of the same
SoC family, `[user]` = ask.

## Contents
1. Identity and platform
2. Boot image of the stock recovery
3. Partition layout
4. Userdata encryption
5. Trusted-execution chain (Keymaster / Gatekeeper / TEE daemon)
6. Kernel
7. USB, display, input
8. Artifacts to obtain from the ROM
9. Reference trees to look for
10. Unknowns that are cheap to resolve by testing

## 1. Identity and platform
| fact | source | goes to |
|---|---|---|
| codename (`ro.product.device`), brand, model | [rom] | `DEVICE`, `BRAND`, `MODEL`, `OEM` (lower-case brand) |
| SoC platform (`ro.board.platform`), `ro.hardware` | [rom] | `PLATFORM`, `HARDWARE` (names `init.recovery.<hw>.rc`, `ueventd.<hw>.rc`) |
| 64-bit with 32-bit userspace? (`ro.product.cpu.abilist`) | [rom] | the template assumes arm64 + arm; a 64-only device needs the 2nd-arch lines removed |
| CPU cores (`CPU part` lines of /proc/cpuinfo) | [rom] | `CPU_VARIANT_RUNTIME` (0xd0b = cortex-a76, 0xd05 = a55, 0xd0d = a77); `generic` is safe |
| first API level (`ro.product.first_api_level`) | [rom] | `SHIPPING_API_LEVEL` |
| A/B? (`ro.build.ab_update`, `ro.boot.slot_suffix`) | [rom] | `AB` (the template does not support A/B) |
| is the bootloader unlocked? `fastboot getvar unlocked` / `ro.boot.flash.locked` | [user]/[rom] | a locked bootloader will not boot any custom recovery: stop here |

## 2. Boot image of the stock recovery
Run `unpack_and_inspect_boot.sh` on the stock `recovery.img` (or `boot.img` when the device has no recovery partition).
* header version, page size, base and offsets, command line -> `BOOT_HEADER_VERSION`, `PAGESIZE`, `KERNEL_BASE`, `*_OFFSET`, `KERNEL_CMDLINE`.
* a separate dtb in the image (header v2) -> `DTB`; none and a kernel with an appended dtb (`Image.gz-dtb`) -> `KERNEL_IMAGE_NAME=Image.gz-dtb`, `DTB=` empty.
* `recovery_dtbo` -> `DTBO`.
* The command line: keep `console=`, `earlycon=`, `androidboot.hardware=`, `androidboot.console=`, `androidboot.usbcontroller=`,
  `androidboot.dynamic_partitions=true` (without it the decrypt trigger of the common Qualcomm init files never fires on a
  dynamic-partition device), `androidboot.selinux=permissive` and whatever the stock recovery carries that is not per boot. The
  bootloader appends its own `androidboot.*` items at boot (and on Qualcomm usually `ramoops_memreserve=4M`, which is what
  makes pstore work): compare with `cat /proc/cmdline` of the running stock recovery and do not copy those into BoardConfig.
* Image sizes: the recovery partition size in bytes: `cat /sys/class/block/<sdXN>/size` times 512, or `fastboot getvar partition-size:recovery`
  -> `RECOVERY_PARTITION_SIZE`. The built image is padded to exactly this size.

## 3. Partition layout
* by-name list [rom] -> `PARTITIONS` (the generated `twrp.flags` follows it: boot, recovery, cache, metadata, misc, dtbo, modem, persist ...).
* `super` present -> `DYNAMIC_PARTITIONS=yes`; `SUPER_SIZE` = bytes of the super partition; `SUPER_GROUP` and the logical partition
  list come from `lpdump` (root) or from the ROM's OTA metadata; `ro.boot.dynamic_partitions=true`.
* `metadata` partition present -> `USES_METADATA_PARTITION=yes` (metadata encryption keeps its key there).
* `cache` size -> `CACHE_PARTITION_SIZE` (the black-box recorder writes to /cache).
* userdata file system (f2fs or ext4) -> `USERDATA_FS`.

## 4. Userdata encryption
The `userdata` line of the ROM's own fstab (`/vendor/etc/fstab.<hw>`, in the output of the facts script) is the ground truth.
Split it into the three fields the generator wants:
```
<src> <mnt_point> <type> <mnt_flags and options>   <fs_mgr_flags>
userdata /data f2fs noatime,nosuid,...,inlinecrypt,...,compress_extension=so   latemount,wait,...,fileencryption=...,metadata_encryption=...,keydirectory=...,fscompress,...
```
* field 4 -> `DATA_MNT_FLAGS` (keep `inlinecrypt` and every f2fs option: they are needed to mount an inline-crypto userdata),
* field 5 -> `DATA_FS_MGR_FLAGS`,
* the crypto subset of field 5 (`fileencryption=..., metadata_encryption=..., keydirectory=..., fscompress`) -> `DATA_TWRP_FLAGS`.
Decide `CRYPTO_MODE` with the table in SKILL.md. If the ROM is not running (only an image is available), the same line is
in the ramdisk's first-stage fstab (`/vendor_boot` ramdisk or `boot` ramdisk, `fstab.<hw>`) or in `vendor.img` under `etc/fstab.<hw>`.
`recovery-fbe-decryption/references/fstab-and-flags-mapping.md` explains every token.

## 5. Trusted-execution chain
| fact | source | goes to |
|---|---|---|
| Keymaster / KeyMint HAL version(s) | [rom] "HAL manifest entries" | `KEYMASTER_VERSIONS` (HIDL `4.0`/`4.1`); an AIDL `android.hardware.security.keymint` HAL = unverified territory, read `other-socs.md` |
| Gatekeeper HAL version | [rom] | `GATEKEEPER_VERSION` |
| Weaver HAL present (Pixel-class) | [rom] | `WEAVER` |
| service stanzas (user, group, capabilities, env) of those HALs and of the TEE daemon | [rom] "init service stanzas" | mirror them in the recovery rc if the common init files lack the service |
| TEE daemon binary (`qseecomd` on Qualcomm) and the libraries of the HALs | [rom] binaries list; `collect_decrypt_blobs.py` | `recovery/root/system/bin` + `recovery/root/vendor/lib64` |
| trusted-app firmware directory (Qualcomm: `/vendor/firmware_mnt/image`, partition `modem`) | [rom] "trusted-app firmware" | `MOUNT_FIRMWARE=yes`, `FIRMWARE_PARTITION` |
| vendor manifest `target-level`, `sepolicy` version | [rom] | `VINTF_TARGET_LEVEL`, `VINTF_SEPOLICY` |

## 6. Kernel
* kernel version of the stock recovery vs. the ROM's kernel (`uname -r`); if the ROM's kernel is newer or from another
  family than the stock one, the stock kernel probably lacks what the userdata needs -> use the ROM's kernel (SKILL.md step 3).
* `/proc/config.gz` of the ROM, when present, lists FS_ENCRYPTION, FS_ENCRYPTION_INLINE_CRYPT, BLK_INLINE_ENCRYPTION, DM_DEFAULT_KEY,
  F2FS_FS_COMPRESSION, EROFS_FS, RD_LZMA, PSTORE_RAM: all of them must be on in the recovery's kernel when the fstab uses the feature.
* The kernel image format of the ROM's `boot.img` (gzip `Image.gz`, plain `Image`, `Image.gz-dtb`) -> `KERNEL_PREBUILT`, `KERNEL_IMAGE_NAME`.

## 7. USB, display, input
* USB controller name (`ls /sys/class/udc`) -> `USB_CONTROLLER`; the common gadget init is in `init.recovery.usb.rc`.
* resolution (`wm size`), brightness node and range (`/sys/class/backlight/*`), notch -> `SCREEN_W/H`, `BRIGHTNESS_PATH`, `MAX_BRIGHTNESS`, `HIDE_NOTCH`.
* input devices that must be ignored (a proximity sensor that registers as a touch device) -> `INPUT_BLACKLIST`; the official tree of the device usually knows.

## 8. Artifacts to obtain from the ROM
| artifact | how | used for |
|---|---|---|
| `boot.img` | the ROM's release files, or `payload.bin` of its OTA zip with `payload-dumper-go`; ROM projects often publish it separately | its kernel (and dtb) become the recovery kernel |
| `dtbo.img` | same, or the device's own `dtbo` partition | `prebuilt/dtbo.img` |
| `vendor.img` | `payload.bin` again; or pull from the running ROM | blobs of the decryption stack (`collect_decrypt_blobs.py` can pull them over adb from the running ROM) |
| the ROM's `fstab.<hw>` | [rom] | crypto flags |
Never pull blobs from a different ROM version than the one whose firmware (modem partition) is on the phone: the trusted app
and the userspace libraries have to match each other.

## 9. Reference trees to look for
Official OrangeFox (gitlab.com/OrangeFox/device), TWRP (github.com/TeamWin), LineageOS (`android_device_<oem>_<codename>` and the
`android_device_<oem>_<platform>-common` trees) for the same device, or for another device on the same SoC (for the reference
port: `sweet` and `miatoll` for SM6150). Take from them: `ueventd.<hw>.rc`, the display/touch/brightness settings, the vendor
blob list, the framework VINTF manifest idea. Compare, do not copy blindly: their fstab flags belong to their ROM.

## 10. Unknowns that are cheap to resolve by testing
* does `fastboot boot` work on this bootloader (some refuse), and is the control image (ROM recovery) reliable;
* is `adb` reachable from the recovery on the user's computer (Windows needs a driver; Linux needs a udev rule);
* is pstore alive: `ls /sys/fs/pstore` after a deliberate panic is impractical, so just check the command line and
  `/sys/module/ramoops/parameters` in the facts output.
