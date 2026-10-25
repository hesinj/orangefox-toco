# The decryption chain in a recovery

## Contents
1. What encrypts /data (and what a recovery must undo)
2. Components, in start order
3. How OrangeFox picks the Keymaster service
4. OS version and patch level
5. Timeline of a working boot
6. Where the code lives

## 1. What encrypts /data
| layer | what it is | fstab token | recovery side |
|---|---|---|---|
| FDE (dm-crypt, Android 9 and older) | whole-partition encryption keyed by the lock-screen secret | `forceencrypt=` / `encryptable=` | `BOARD_USES_QCOM_DECRYPTION`, `TW_INCLUDE_CRYPTO` (not covered by the reference port) |
| FBE v1 / v2 (fscrypt) | per-file keys; v2 policies carry a key identifier and use the kernel keyring (`FS_IOC_ADD_ENCRYPTION_KEY`) | `fileencryption=<contents>:<filenames>[:v2]` | `TW_INCLUDE_CRYPTO_FBE`, `TW_USE_FSCRYPT_POLICY := 1 or 2` |
| metadata encryption | the whole data partition (including file-system structures) sits on a dm-default-key device | `metadata_encryption=<mode>`, `keydirectory=` | `TW_INCLUDE_FBE_METADATA_DECRYPT`, `/metadata` mounted, kernel `dm-default-key` |
| hardware-wrapped keys | the key never appears in kernel memory; the storage controller's inline crypto engine (UFS ICE) is programmed with a key that only the secure world can unwrap | `wrappedkey_v0`, `inlinecrypt_optimized` | kernel with blk-crypto and wrapped-key support; the TEE chain must answer |
| device-encrypted (DE) vs credential-encrypted (CE) keys | DE keys open at boot (system data); CE keys need the user's secret | - | the OrangeFox password page unlocks CE through Gatekeeper |
Keys are stored as blobs (`keymaster_key_blob`) under `/metadata/vold/metadata_encryption/key` (metadata layer), `/data/unencrypted/key`
(system-wide DE), `/data/misc/vold/user_keys/{de,ce}/<user>/` and the synthetic-password files under `/data/system_de/<user>/spblob`.
A blob is only meaningful to the Keymaster trusted app of the same device (it is bound to the device's hardware keys).

## 2. Components, in start order
1. **init** (recovery ramdisk): `fs` stage mounts `/vendor/firmware_mnt`; symlinks `/dev/block/bootdevice`.
2. **servicemanager, hwservicemanager, vndservicemanager**: binder context managers. `hwservicemanager` reads the VINTF manifests
   (`/system/etc/vintf/manifest.xml` framework, `/vendor/etc/vintf/manifest.xml` device) to know which HIDL HALs may register.
3. **recovery** (TWRP/OrangeFox main process, user root, SELinux permissive): detects the encrypted data partition (flags in
   `twrp.flags`/`recovery.fstab`), sets `ro.crypto.state=encrypted`, and calls `fscrypt_mount_metadata_encrypted()` from `Decrypt_Data()` before the GUI.
4. **prepdecrypt** (`device/qcom/twrp-common`, triggered by `ro.crypto.state=encrypted && ro.boot.dynamic_partitions=true`; the build strips the second
   condition when `PRODUCT_USE_DYNAMIC_PARTITIONS` is not true): logs `File Based Encryption (FBE) is present`, fixes up OS version/patch properties, sets `crypto.ready=1`.
5. **qseecomd** (started by `crypto.ready=1 && hwservicemanager.ready=true`): initialises RPMB and SSD (mandatory, as root), registers its listeners and
   sets `vendor.sys.listeners.registered=true`. Optional listeners (`libspl`, `libops`, `libsecureui`) log `dlopen ... not found`: harmless.
6. **Keymaster HAL** (`android.hardware.keymaster@4.x-service-qti`, started per `keymaster_ver`): loads the Keymaster trusted app from `/vendor/firmware_mnt/image`
   into the secure world (TA API version appears in its log), registers with hwservicemanager.
7. **gatekeeper HAL** (`android.hardware.gatekeeper@1.0-service-qti`): started by the same listener property; used by the password page.
8. **keystore2** (from the ramdisk; `km_compat` adapts the HIDL Keymaster to KeyMint). The recovery's vold code calls it to unwrap the metadata key
   (`Retrieving key from keymaster`), builds the dm-default-key device, `libfs_mgr` runs `fsck.f2fs -a` and mounts `/data`.
9. The recovery then installs the system-wide DE keys and user 0's DE keys (`fscrypt_init_user0`), and later, with the password, the CE keys.

## 3. How OrangeFox picks the Keymaster service
`Process_Keymaster_Version()` (partitionmanager.cpp) mounts the ROM's vendor partition briefly and reads `android.hardware.keymaster` from
`/vendor/etc/vintf/manifest.xml` (or `manifest_<platform>.xml`). Any `4.x` becomes `keymaster_ver=4.x`, which the common init file maps to
*all* of keymaster 4.0 / 4.1 / citadel services that exist in the ramdisk. If no manifest is found the property `keymaster_ver` (from the device tree) or `4.x` is used.
Overrides: `TW_FORCE_KEYMASTER_VER` + `OF_DEFAULT_KEYMASTER_VERSION`, `OF_NO_KEYMASTER_VER_4X`. Log lines: `Keymaster_Ver::Using keymaster version '4.x' for decryption`.

## 4. OS version and patch level
The Keymaster trusted app binds keys to an OS version and patch level and rejects a key whose level is higher than the running one. A recovery has no
real OS, so the tree claims `PLATFORM_VERSION := 99.87.36` and `PLATFORM_SECURITY_PATCH := 2099-12-31` (TWRP convention; `prepdecrypt.sh` carries the same defaults and,
on devices without a recovery partition, may replace them with the installed ROM's real values). Consequence: every key use logs `Upgrading key`, because the
trusted app returns an upgraded blob. In the vold copy of OrangeFox/TWRP the upgraded blob is written to `/tmp/keymaster_key_blob/` (RAM) and never committed.

## 5. Timeline of a working boot (reference device, LZMA ramdisk)
kernel up 0 s, ramdisk freed 2.1 s, init first stage 4.2 s, second stage 6.3 s, recovery/keystore2/hwservicemanager 6.5 s, prepdecrypt 7.1 s,
qseecomd 8.3 s, Keymaster HAL + gatekeeper 8.35 s, USB gadget 11.8 s, `/data` mounted (dm-5) before 12.4 s, adb answering 11.8 s, password page after that.

## 6. Where the code lives (OrangeFox fox_12.1 tree)
* `bootable/recovery/partitionmanager.cpp`: `Decrypt_Data()`, `Process_Keymaster_Version()`, `Process_ResetProps()`.
* `system/vold/` (TWRP's modified copy): `MetadataCrypt.cpp`, `KeyStorage.cpp` (key upgrade kept in `/tmp`), `KeyUtil.cpp`, `FsCrypt.cpp`.
* `device/qcom/twrp-common/`: `crypto/init.recovery.qcom_decrypt.rc` (services and triggers), `crypto/system/bin/prepdecrypt.sh`, `crypto_fbe/init.recovery.qcom_decrypt.fbe.rc`.
* The OrangeFox patch of this skill set changes only `partitionmanager.cpp` and `twrp.cpp`.
