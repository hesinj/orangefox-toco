# From the ROM's fstab to the recovery's flags

The ROM's own fstab is the ground truth for what `/data` uses. Where to find it: `/vendor/etc/fstab.<hw>` (or `fstab.qcom`, `fstab.default`) of the running
ROM (the facts script of `orangefox-fbe-recovery-port` prints the userdata line); in the ROM zip or `vendor.img` as `etc/fstab.<hw>`; in the ramdisk of
`boot`/`vendor_boot` for first-stage mounts. The reference device's line (PixelOS Android 16):

```
userdata /data f2fs noatime,nosuid,nodev,nodiscard,reserve_root=32768,resgid=1065,fsync_mode=nobarrier,inlinecrypt,background_gc=sync,gc_merge,atgc,checkpoint_merge,compress_extension=apk,compress_extension=apex,compress_extension=so latemount,wait,check,formattable,fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized+wrappedkey_v0,metadata_encryption=aes-256-xts:wrappedkey_v0,keydirectory=/metadata/vold/metadata_encryption,fscompress,quota,reservedsize=128M,checkpoint=fs
```

## Token by token
| token | meaning | recovery setting | kernel need |
|---|---|---|---|
| `fileencryption=aes-256-xts:aes-256-cts` | contents mode : filenames mode | the same string in `twrp.flags` (`flags=fileencryption=...`) and `recovery.fstab` | `CONFIG_FS_ENCRYPTION` |
| `:v2` | fscrypt policy version 2 | `TW_USE_FSCRYPT_POLICY := 2` (without it v1 is assumed) | kernel with v2 (`fscrypt-provisioning` marker) |
| `+inlinecrypt_optimized` | use inline crypto, optimised data-unit numbering | keep it in the flags | `CONFIG_FS_ENCRYPTION_INLINE_CRYPT`, `CONFIG_BLK_INLINE_ENCRYPTION`, controller driver (UFS ICE) |
| `+wrappedkey_v0` | the file keys are hardware-wrapped (version 0 format) | keep it in the flags | wrapped-key support in the crypto engine driver; TEE chain must answer |
| `metadata_encryption=aes-256-xts:wrappedkey_v0` | metadata layer (dm-default-key), mode and wrapped-key option | `TW_INCLUDE_FBE_METADATA_DECRYPT := true` and the flag in `twrp.flags` | `dm-default-key` target |
| `keydirectory=/metadata/vold/metadata_encryption` | where the metadata key blob lives | keep; `/metadata` must be mountable | - |
| `fscompress`, `compress_extension=...` | f2fs transparent compression | `OF_ENABLE_FS_COMPRESSION := 1`, `PRODUCT_FS_COMPRESSION := 1`, keep `fscompress` | `CONFIG_F2FS_FS_COMPRESSION` |
| `inlinecrypt` (mount option, field 4) | mount f2fs with inline encryption | keep in `recovery.fstab` field 4 | as above |
| `latemount,wait,check,formattable,quota` | fs_mgr behaviour | copy; `check` makes libfs_mgr run `fsck.f2fs -a` before the mount | - |
| `reservedsize=128M`, `checkpoint=fs` | unknown to the recovery's fs_mgr | "Unhandled flag" in the log, harmless | - |
| `reserve_root`, `resgid`, `fsync_mode`, `gc_merge`, `atgc`, `checkpoint_merge` | f2fs mount options | copy as is | the kernel must know them; unknown options make the mount fail |

## Deciding `CRYPTO_MODE` for the generator
* no `fileencryption=` and `forceencrypt`/`encryptable` -> `fde`;
* `fileencryption=` only -> `fbe` (policy 1 or 2 by `:v2`);
* plus `metadata_encryption=` -> `fbe_metadata`; plus `wrappedkey` -> `fbe_metadata_wrapped` (rendered the same; the name is a reminder that the TEE chain is mandatory);
* an `fscrypt`/`FBE` userdata *without* hardware wrapping can be opened with software keys only if Keymaster is software (rare on Qualcomm: still needs the TEE chain).

## Pitfalls
* **Do not copy the flags of another ROM.** A different Android version of the same phone can use another policy version or no metadata encryption.
* **A kernel built from an older source drops options silently**: `inlinecrypt`, `compress_extension`, `atgc` unknown to the kernel make the mount fail with `Invalid argument`.
* `twrp.flags` takes only the crypto part (`fileencryption=...,metadata_encryption=...,keydirectory=...,fscompress`), `recovery.fstab` the full mount options and fs_mgr flags.
* Writing the same string in both files is intended: `twrp.flags` is what the TWRP/OrangeFox crypto code parses, `recovery.fstab` is what `libfs_mgr` mounts with.
* The first `Unable to mount '/data'` / `F2FS-fs: Magic Mismatch` lines before the decrypt are normal: the raw partition is encrypted.
