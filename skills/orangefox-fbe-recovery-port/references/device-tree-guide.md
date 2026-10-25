# Device tree guide: what each generated file does

The generator (`scripts/new_device_from_template.py`) writes the tree below. Everything is plain OrangeFox/TWRP device-tree
convention; this guide records the reasons behind the lines that took debugging to get right. Source of truth for a finished
tree: https://github.com/hesinj/orangefox-toco (the template renders to it, see `assets/device.conf.example`).

## Contents
1. Layout of the tree
2. BoardConfig.mk
3. device.mk
4. fox_<codename>.mk (OrangeFox switches)
5. recovery/root: init, fstab, flags, manifests, scripts, blobs
6. The OrangeFox patch
7. A/B, recovery-in-boot, vendor_boot (not covered by the template)
8. Pitfalls that cost builds

## 1. Layout
```
device/<oem>/<codename>/
  Android.mk  AndroidProducts.mk  twrp_<codename>.mk  device.mk  fox_<codename>.mk  BoardConfig.mk  vendorsetup.sh
  prebuilt/            kernel (Image.gz), dtb, dtbo.img          (you add; not generated)
  patches/             0001-startup-hardening.patch              (applied to bootable/recovery, not part of the tree build)
  port/device.conf     the configuration the files were generated from
  recovery/root/
    init.recovery.<hw>.rc   init.recovery.usb.rc   ueventd.<hw>.rc
    system/etc/recovery.fstab   system/etc/twrp.flags   system/etc/vintf/manifest.xml
    system/bin/  fox_decrypt_diag.sh  fox_blackbox.sh  qseecomd  android.hardware.keymaster@*-service*  android.hardware.gatekeeper@*-service*
    vendor/etc/vintf/manifest.xml
    vendor/lib64/ ...      libraries of the decryption stack (collect_decrypt_blobs.py)
```
The lunch target is `twrp_<codename>-eng`; `vendorsetup.sh` only exports OrangeFox variables when `FOX_BUILD_DEVICE=<codename>` is set,
which is why the build scripts export it.

## 2. BoardConfig.mk
* **Architecture block**: arm64 + arm second arch is the standard layout of a 64-bit phone. A 64-only device (rare, Android 13+ flagships)
  must delete the `TARGET_2ND_*` lines. `TARGET_CPU_VARIANT_RUNTIME` only picks optimised libc routines; `generic` is safe.
* **Boot image block**: base/offsets/page size/header version come from the stock recovery (`unpack_and_inspect_boot.sh`). The
  `--dtb`/`--dtb_offset` mkbootimg arguments are for header v2 images that carry a separate dtb; an appended-dtb kernel is
  `Image.gz-dtb` and has no `--dtb`. `BOARD_INCLUDE_RECOVERY_DTBO := true` packs `dtbo.img` into the image (header v1/v2).
* **Kernel command line**: see the intake checklist. `panic=0` is deliberate while the recovery is unproven: a panic then freezes
  the phone instead of restarting it (and a restart after `fastboot boot` lands in the installed ROM and hides the panic).
  Remove it for a release once the recovery has run stably.
* **Ramdisk compression**: gzip by default, `FOX_LZMA_RAMDISK=true` switches to LZMA (35% smaller; the kernel needs `CONFIG_RD_LZMA`; the
  host `lzma` binary must exist: OrangeFox builds use `prebuilts/tools-lineage/linux-x86/bin/lzma`). The kernel's decompressors are gzip,
  bzip2, lzma, lzo, lz4 and zstd depending on `CONFIG_RD_*` (the reference kernel had gzip, bzip2, lz4 and lzma, **no xz**; the facts script
  prints the RD_* options of the ROM kernel). Verify an LZMA ramdisk with the kernel's own decoder
  (`recovery-boot-debugging/scripts/unlzma_check/`).
* **AVB**: the recovery image gets a footer signed with AOSP's test key and `--flag 2`; an unlocked bootloader boots it (orange state).
  The image is padded to exactly `BOARD_RECOVERYIMAGE_PARTITION_SIZE`.
* **Dynamic partitions**: `BOARD_SUPER_PARTITION_SIZE`, the group name, `BOARD_<GROUP>_SIZE` (group size is super size minus 4 MiB overhead
  on the reference device) and the partition list. They describe the logical-partition layout to the build and to OrangeFox's partition
  handling (backup/restore of logical partitions). On the reference device they were copied from the ROM; whether a wrong value would
  also break booting or decrypting was not tested.
* **File systems**: `TARGET_USERIMAGES_USE_F2FS`, `..._EROFS`, `PRODUCT_FS_COMPRESSION := 1` when the userdata is f2fs with compression.
* **TW_EXCLUDE_MTP**: on the reference device starting MTP re-programs the USB gadget (adbd is killed and re-enumerates) a few seconds
  after boot and the legacy MTP function failed anyway. Rescue work is more reliable over adb. Building with `TW_EXCLUDE_MTP` needs
  `#include <private/android_filesystem_config.h>` in `bootable/recovery/partitionmanager.cpp` (AID_MEDIA_RW otherwise arrives through
  the MTP headers); the OrangeFox patch adds the include.
* **Variant switch**: `FOX_VARIANT=nocrypt` (exported before `lunch`) drops all crypto flags and packages.
* **Crypto flags** (see `recovery-fbe-decryption`): `TW_INCLUDE_CRYPTO`, `TW_INCLUDE_CRYPTO_FBE`, `TW_USE_FSCRYPT_POLICY` (1 or 2),
  `TW_INCLUDE_FBE_METADATA_DECRYPT`, and for Qualcomm `BOARD_USES_QCOM_FBE_DECRYPTION` (FDE: `BOARD_USES_QCOM_DECRYPTION`).
* `BUILD_BROKEN_MISSING_REQUIRED_MODULES := true` and `ALLOW_MISSING_DEPENDENCIES=true` (exported by the build script) are inherited from the
  reference trees: the TWRP minimal manifest does not contain every module the common decrypt packages and the OrangeFox additions name as
  required. Not investigated further; they were needed in practice.

## 3. device.mk
* `PRODUCT_PACKAGES += qcom_decrypt qcom_decrypt_fbe` pulls `device/qcom/twrp-common` (part of the OrangeFox sync): `init.recovery.qcom_decrypt.rc`
  (service stanzas for prepdecrypt, qseecomd, keymaster 3.0/4.0/4.1, gatekeeper, plus the property triggers), `prepdecrypt.sh`, and
  `init.recovery.qcom_decrypt.fbe.rc`. Without `BOARD_USES_QCOM_FBE_DECRYPTION` the packages do nothing.
* `PLATFORM_VERSION := 99.87.36`, `PLATFORM_SECURITY_PATCH := 2099-12-31`: the recovery claims an OS version higher than any real one so
  that the Keymaster trusted app never sees a lower level than the one a key is bound to. Side effect: "Upgrading key" log lines (the
  upgraded blob stays in RAM). `prepdecrypt.sh` has the same defaults and may replace them with the ROM's real values on devices that
  boot recovery from the boot partition.
* `TARGET_RECOVERY_DEVICE_MODULES += libion libxml2` (+ `RECOVERY_LIBRARY_SOURCE_FILES`): `libQSEEComAPI` needs libion, `libdrmfs` needs libxml2;
  the recovery ramdisk does not contain them otherwise (verify_ramdisk.py catches it).
* `TW_NO_SCREEN_BLANK`, `TW_FRAMERATE`, `TW_INPUT_BLACKLIST`, `TW_BRIGHTNESS_PATH`: copied from the official trees of the same SoC. A
  wrong brightness path gives a black or dim screen that still works; a missing input blacklist can make touch jump.

## 4. fox_<codename>.mk (OrangeFox switches)
Conservative on purpose for an unproven recovery:
* `OF_DONT_PATCH_ON_FRESH_INSTALLATION := 1` and **no** `OF_PATCH_AVB20`: OrangeFox must not hex-patch the real boot partition's AVB footer
  before reboot or repack the boot image on a zip install. Switch them on later, deliberately.
* `OF_DONT_PATCH_ENCRYPTED_DEVICE := 1`: do not patch boot/vbmeta to remove forced encryption on an encrypted device.
* `OF_FBE_METADATA_MOUNT_IGNORE := 1`: only silences the "Failed to mount /metadata" message (partition.cpp). Harmless.
* `OF_ENABLE_FS_COMPRESSION := 1`: required when the userdata uses f2fs compression (kernel `CONFIG_F2FS_FS_COMPRESSION`, `fscompress` in the flags).
* `OF_ENABLE_LPTOOLS := 1` needs `external/lptools` in the tree (the OrangeFox sync clones it; the build stops with an error if absent).
* `OF_USE_MAGISKBOOT*`, OTA flags, screen/notch flags: see OrangeFox's `orangefox.mk` for each; they do not affect booting or decryption.

## 5. recovery/root
* **`init.recovery.<hw>.rc`**: `wait` + `symlink /dev/block/platform/soc/${ro.boot.bootdevice} /dev/block/bootdevice` (the by-name paths of
  every fstab line depend on it); the firmware mount (below); USB controller property; `start health-hal-2-1` (battery status); the black-box
  recorder and the decrypt diagnostics. `import /init.recovery.qcom_decrypt.rc` is added by the build if missing, with a warning.
* **Firmware mount**: on Qualcomm the Keymaster HAL (`libkeymasterdeviceutils`) loads its trusted app from the hard-coded `/vendor/firmware_mnt/image`,
  which on a booted ROM is the `modem` partition (vfat). The recovery mounts it read-only from init (`on fs`). The `mounttodecrypt` flag in
  `twrp.flags` is **not** enough: this OrangeFox source honours it only when a password is typed (`Decrypt_Device()`), not in the metadata decrypt
  that runs before the GUI.
* **`init.recovery.usb.rc`**: configfs gadget with adb (FunctionFS) and mtp; `ro.boot.usbcontroller` from the command line or
  `sys.usb.controller` from the rc selects the UDC. If adb never shows up, check `ls /sys/class/udc` on the ROM and the rc.
* **`recovery.fstab`** mirrors the ROM: logical partitions (`wait,logical,first_stage_mount`; both ext4 and erofs lines so either works),
  `/metadata` (`first_stage_mount` so it is mounted before the decrypt), `/data` copied from the ROM line. Unknown flags (`reservedsize=`,
  `checkpoint=fs`) log "Unhandled flag" and are harmless.
* **`twrp.flags`**: `/data ... flags=fileencryption=...,metadata_encryption=...,keydirectory=...,fscompress` is what the crypto code reads.
  The other lines are the usual Qualcomm backup partitions; the generated file follows the `PARTITIONS` list.
* **VINTF manifests**: `system/etc/vintf/manifest.xml` (framework) and `vendor/etc/vintf/manifest.xml` (device). **Without the framework manifest
  keystore2 crash-loops** and nothing is decrypted: details in `recovery-fbe-decryption`. The device manifest declares exactly the HAL
  services whose binaries are in the ramdisk.
* **`ueventd.<hw>.rc`**: device-node permissions. Missing rules show as `/dev/qseecom` or `/dev/sg*` owned by root with mode 0600 and a TEE
  daemon that cannot open them. Copy from a reference tree of the same SoC.
* **`fox_decrypt_diag.sh` / `fox_blackbox.sh`**: recorded state of the decrypt chain / of the whole boot (`recovery-fbe-decryption`,
  `recovery-boot-debugging`).
* **Binaries**: from Android 10 trees on, daemons go to `system/bin` of the ramdisk and libraries to `vendor/lib64`; the init stanzas set
  `LD_LIBRARY_PATH` to `/vendor/lib64:/vendor/lib:/system/lib64:/system/lib:/sbin`.

## 6. The OrangeFox patch (`patches/0001-startup-hardening.patch`)
Applies to `bootable/recovery` of OrangeFox `fox_12.1` (checked against 4f00a3d): `cd bootable/recovery && git apply --check <patch> && git apply <patch>`
(a "type 100644, expected 100755" warning is harmless).
1. The metadata decrypt (`fscrypt_mount_metadata_encrypted`) runs in a worker thread and is abandoned after 90 s (property
   `fox.decrypt.timeout`, minimum 10): without it a missing link of the chain blocks the recovery on the splash screen forever, with an empty
   log. While waiting, every 5 s the state of each service is logged; property `fox.decrypt.state` becomes running / done / failed / timeout.
2. libbase logging (vold code, keystore glue) goes to logd **and** stderr, i.e. into `/tmp/recovery.log`; otherwise the recovery log is silent
   about why a decrypt failed.
3. If the GUI never starts (`gui_start()` returns non-zero) the process holds with adbd alive instead of rebooting, so the log can be read.
4. Adds the `private/android_filesystem_config.h` include needed by `TW_EXCLUDE_MTP`.
Re-check the patch against any other OrangeFox branch before using it there.

## 7. A/B, recovery-in-boot, vendor_boot (unverified: not part of the reference port)
A/B devices usually have no `recovery` partition; the recovery is the ramdisk of `boot` (`BOARD_USES_RECOVERY_AS_BOOT := true`), or lives in
`vendor_boot` with header v3/v4 (`BOARD_INCLUDE_RECOVERY_RAMDISK_IN_VENDOR_BOOT`, `BOARD_MOVE_RECOVERY_RESOURCES_TO_VENDOR_BOOT`, `BOARD_BOOT_HEADER_VERSION := 3|4`,
`BOARD_RAMDISK_USE_LZ4`, kernel and dtb in the boot/vendor_boot images). Copy that block from an official tree of the same SoC/Android version,
then reuse this skill set for the crypto and debugging parts. On recovery-in-boot devices `fastboot boot recovery.img` of a boot-format image is the
test method; flashing replaces the boot partition: do not do it without a known-good boot image at hand. `prepdecrypt.sh` decides from the presence
of `/dev/block/bootdevice/by-name/recovery` whether to read the real OS version/patch level (`SETPATCH=true` when there is none).

## 8. Pitfalls that cost builds
* **Stale staging directories.** `out/target/product/<codename>/{root,recovery,fake_packages}` are not cleaned between builds. A file removed from the tree
  stays in the next image, and a `nocrypt` build inherits the decrypt init files of the previous full build. The build script removes them before
  every build; `verify_image.sh` compares the ramdisk to the tree.
* **The device tree in the build is a copy.** Edit in the repo, then sync into `<fox>/device/<oem>/<codename>` (`sync_tree.sh`) and never during a build.
* **Do not trust embedded kernel configs.** `/proc/config.gz` or IKCONFIG of a prebuilt kernel can be a stale blob (both PixelOS kernels carried the
  same 4.14.180 config): compare kernels by their strings and symbols instead (`recovery-boot-debugging`).
* **Do not delete the second clang directory** of the OrangeFox tree (`prebuilts/clang/host/linux-x86/clang-r416183b`): the prebuilt rustc and bindgen
  reference it without ninja knowing (`recovery-build-environment`).
* **Binaries are not source.** Vendor blobs must match the ROM firmware on the phone; keep their provenance in NOTICE.md.
