---
name: recovery-fbe-decryption
description: Make a custom recovery (OrangeFox or TWRP) decrypt and mount an Android phone's encrypted /data - file-based encryption (FBE v1 and v2), metadata encryption, hardware-wrapped keys, the Keymaster / KeyMint / Gatekeeper HALs and the Qualcomm TEE daemon qseecomd. Use when a recovery shows 0 MB or scrambled file names in internal storage, asks for a password and rejects it, logs prepdecrypt, keystore2, qseecomd or Keymaster errors, sits on the splash screen after 'Device ready for decryption', or when someone wants to rescue files from an encrypted phone through its recovery. Covers reading the ROM's fstab, the build flags, what the ramdisk must contain, VINTF manifests, diagnostics, failure signatures and key safety.
---

# Decrypting /data in a custom recovery

How a recovery opens an encrypted `/data`, what it needs, and how to find the missing piece when it does not. Everything here was
verified on one device (Snapdragon 730G, PixelOS Android 16 userdata: FBE v2 + metadata encryption + hardware-wrapped keys,
Qualcomm Keymaster 4.1 HIDL HAL, OrangeFox `fox_12.1`); other SoCs are marked unverified in `references/other-socs.md`.
Paths are relative to this skill's directory. Sibling skills: `orangefox-fbe-recovery-port` (whole workflow, device tree),
`recovery-boot-debugging` (panics, freezes), `recovery-build-environment` (building and static checks), `android-data-rescue-adb` (copying data).

## The chain (each link waits for the next, without a time limit)

```
recovery process (vold code of TWRP 12.1: fscrypt_mount_metadata_encrypted)
  -> keystore2 (km_compat wraps the HIDL Keymaster as KeyMint)           needs the framework VINTF manifest
  -> Keymaster 4.x HAL service (vendor, QTI)                             needs its trusted app from /vendor/firmware_mnt (modem partition)
  -> qseecomd (Qualcomm TEE daemon: RPMB + SSD listeners)  -> /dev/qseecom -> TrustZone
gatekeeper HAL (password check) is the second consumer, after the metadata layer is open
```
On success the recovery log shows, in this order: `prepdecrypt::Script complete`, `Retrieving key from keymaster`,
`Successfully decrypted metadata encrypted data partition ... dm-N`, `fscrypt_init_user0`, property `fox.decrypt.state=done`;
the password page then unlocks the user's credential-encrypted storage. Details and timing: `references/decryption-chain.md`.

## Workflow

1. **Read the ROM's userdata line** (`/vendor/etc/fstab.*` of the running ROM) and map every flag (`references/fstab-and-flags-mapping.md`):
   `fileencryption=...:v2` -> `TW_USE_FSCRYPT_POLICY := 2`; `metadata_encryption=` -> `TW_INCLUDE_FBE_METADATA_DECRYPT` and a `/metadata` partition;
   `wrappedkey_v0` / `inlinecrypt` -> a kernel with inline crypto and wrapped keys; `fscompress` -> f2fs compression in the kernel.
2. **Check the kernel** with `scripts/kernel_marker_check.sh <kernel>`: the stock kernel of an older ROM usually lacks fscrypt v2, blk-crypto,
   dm-default-key and wrapped keys. The safe kernel is the one in the `boot.img` of the ROM being read.
3. **Put the stack into the ramdisk** (`references/ramdisk-contents.md`):
   * blobs: `scripts/collect_decrypt_blobs.py --adb --out <tree>/recovery/root` (from the running ROM) or `--vendor-root <dir>`; it copies
     qseecomd, the HAL services and their full library closure and skips the optional libraries that drag in other stacks;
   * the **framework VINTF manifest** (`assets/vintf/framework_manifest.xml`) and a device manifest (`assets/vintf/vendor_manifest.xml.in`);
   * the init pieces (`assets/init.recovery.HARDWARE.rc.in`): `/vendor/firmware_mnt` mount of the modem partition, diagnostics services;
   * the OrangeFox patch (`assets/0001-startup-hardening.patch`): the decrypt gets a time limit and a log;
   * `ueventd` rules for `/dev/qseecom`, `/dev/ion`, `/dev/sg*` (copy from a reference tree of the SoC);
   * the build flags of step 1 plus `BOARD_USES_QCOM_FBE_DECRYPTION := true` and `PRODUCT_PACKAGES += qcom_decrypt qcom_decrypt_fbe` (Qualcomm).
4. **Check statically** before anybody boots it: unpack the image and run
   `python3 -I scripts/verify_ramdisk.py <ramdisk-dir> --require qseecomd --require 'keymaster|keymint' --require gatekeeper`
   (library closure of every decryption service; it parses the ELF files itself).
5. **Boot and read the logs**: `python3 -I scripts/analyze_recovery_log.py <log bundle dir>` prints the stage table, the services that are not running,
   the matching failure signatures and a verdict. The recovery itself appends `fox-diag:` blocks (`scripts/fox_decrypt_diag.sh`) to `/tmp/recovery.log`.
6. **Fix by signature** (`references/failure-signatures.md`), one change per image.
7. **Keep the user's keys safe** (`references/key-safety.md`): never Format/Wipe, know which writes the decrypt path does and does not do.

## The failures that cost the most time (all verified)
| symptom | cause | fix |
|---|---|---|
| log ends at `prepdecrypt::Script complete`, nothing after, UI never comes | metadata decrypt waits for keystore2, which waits for the Keymaster HAL, ... without a time limit | OrangeFox patch (90 s limit + service state in the log); then find the link |
| `keystore2`: `Check failed: serviceManager.get() Failed to get ServiceManager`; hwservicemanager: `Cannot read /system/etc/vintf/manifest.xml` | the ramdisk has no **framework** VINTF manifest; libhidl will not hand out the HIDL service manager | add `system/etc/vintf/manifest.xml` declaring `android.hidl.manager@1.2` |
| Keymaster HAL cannot load its trusted app | the firmware partition is not mounted at `/vendor/firmware_mnt` | mount it read-only from init (`on fs`); `mounttodecrypt` alone is not enough |
| a library "not found" in a service log | incomplete closure | `verify_ramdisk.py`, `collect_decrypt_blobs.py` |
| `Upgrading key` lines | fake high OS patch level (by design); upgraded blob stays in RAM | expected, harmless |
| metadata decrypt works, password rejected | Gatekeeper (or Weaver on Pixel-class) HAL missing or not started | start it from the `vendor.sys.listeners.registered` trigger |

## What is not covered
Non-Qualcomm TEEs, AIDL KeyMint vendors, vendors that need Weaver, FDE-only devices beyond the flag: see `references/other-socs.md` and treat as unverified.

## Files
* `references/decryption-chain.md`, `fstab-and-flags-mapping.md`, `ramdisk-contents.md`, `failure-signatures.md`, `key-safety.md`, `other-socs.md`
* `scripts/`: `kernel_marker_check.sh`, `collect_decrypt_blobs.py`, `verify_ramdisk.py`, `analyze_recovery_log.py`, `fox_decrypt_diag.sh`
* `assets/`: `vintf/framework_manifest.xml`, `vintf/vendor_manifest.xml.in`, `init.recovery.HARDWARE.rc.in`, `0001-startup-hardening.patch`
