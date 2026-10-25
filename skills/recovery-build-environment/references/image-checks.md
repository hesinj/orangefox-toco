# Static checks of a recovery image

A boot test costs the user minutes and sometimes a bad morning. Everything that can be known from the file alone should be known before the first boot. `scripts/verify_image.sh IMG LABEL yes|no` runs the list below (`yes` = the image should carry the decryption stack, `no` = nocrypt twin); it exits 1 when any check fails.

## Contents
1. What each check means
2. Options by environment
3. Manual commands
4. Reading a failure
5. What static checks cannot tell you

## 1. What each check means
| check | why it matters |
|---|---|
| image is exactly the partition size | `fastboot flash recovery` of a different size either fails or leaves a misaligned AVB footer; `BOARD_RECOVERYIMAGE_PARTITION_SIZE` is read from `BoardConfig.mk` unless `PARTITION_SIZE` is set |
| kernel / dtb / recovery_dtbo identical to the tree's `prebuilt/` files | the image really contains what you think (a stale `out/` can contain the previous kernel) |
| kernel sha256 is the expected one (`KERNEL_SHA256`) | a ROM's kernel binary must stay byte-identical |
| cmdline has / has no `panic=0` (`EXPECT_PANIC0`) | test images want it (a panic freezes, pstore keeps the log); releases do not |
| cmdline free of `FORBID_CMDLINE` | catches debug options (`kasan`, `slub_debug`, `retain_initrd`, `nokaslr`) leaking into a release |
| AVB footer verifies | an image with a broken hash footer is rejected by some bootloaders; the AOSP test key is fine for an unlocked phone |
| ramdisk has the recovery binary | the ramdisk unpacked (compression detected by magic: gzip, lzma, xz, zstd, lz4) |
| every file of `recovery/root` present and identical in the ramdisk | the device tree is what was built; also catches "forgot `sync_tree.sh`" |
| no unexpected files in `vendor/{lib,lib64,bin,etc}` | a file that is in the image but not in the tree is stale (staging directory) or build-produced; WARN by default, FAIL with `STRICT_STALE=yes` |
| framework VINTF manifest declares `android.hidl.manager@1.2` (full only) | without it keystore2 crash-loops (`recovery-fbe-decryption`) |
| recovery has the metadata decrypt strings, and the bounded-decrypt string of the startup patch (full only) | the decrypt code was compiled in, the patch was applied |
| decrypt init rc exists, library closure complete (full only) | `verify_ramdisk.py`: every `DT_NEEDED` and `dlopen` of the decryption services resolves inside the ramdisk |
| no decrypt init rc, no `qseecomd` service anywhere (nocrypt only) | the twin must not start the TEE daemon |

## 2. Options by environment
`FOX_ROOT` (tree, for `unpack_bootimg.py` and `avbtool.py`), `DEVICE_DIR`, `PARTITION_SIZE`, `KERNEL_REF`, `DTB_REF`, `DTBO_REF`, `KERNEL_SHA256`, `EXPECT_PANIC0=yes|no`, `FORBID_CMDLINE='regex'`, `STRICT_STALE=yes`. Example (reference port):
```sh
FOX_ROOT=~/fox_12.1 DEVICE_DIR=~/fox_12.1/device/xiaomi/toco \
KERNEL_REF=~/fox_12.1/device/xiaomi/toco/prebuilt/Image-pixelos.gz KERNEL_SHA256=abf7b66f...(full sha256 of the ROM's kernel blob) \
EXPECT_PANIC0=yes FORBID_CMDLINE='kasan|slub_debug|nokaslr|retain_initrd' \
scripts/verify_image.sh ~/fox_12.1/out/target/product/toco/OrangeFox-R12.0-Unofficial-toco.img r8-full yes
```
Result on the real r8 images: full 15 passed / 0 failed / 1 warning (the three build-produced `vendor/` files), nocrypt 10 passed / 0 failed.

## 3. Manual commands
```sh
python3 -I $FOX/system/tools/mkbootimg/unpack_bootimg.py --boot_img IMG --out /tmp/u      # header, kernel, ramdisk, dtb, recovery_dtbo
python3 -I $FOX/external/avb/avbtool.py info_image --image IMG                            # footer, hash descriptor, algorithm
mkdir /tmp/rd && cd /tmp/rd && gzip -dc /tmp/u/ramdisk | cpio -idm                        # lzma -dc / xz -dc / zstd -dc / lz4 -dc for the others
python3 -I scripts/verify_ramdisk.py /tmp/rd --require qseecomd --require 'keymaster|keymint' --require gatekeeper
```
Run Python on downloaded or extracted data with `-I` and from a different directory than the data (an extracted `json.py` would otherwise be imported).

## 4. Reading a failure
* `missing in image: path` -> the file is in the tree but not in the ramdisk: not synced, or the build did not copy it (check the device tree's `PRODUCT_COPY_FILES` / `recovery/root` path).
* `differs in image` -> an older build left a different copy: delete the staging directories and rebuild.
* `in image, not in the device tree` -> stale file (removed from the tree) or build-produced. Compare with the previous image's list before deciding.
* library closure failure -> the named library is missing in the ramdisk: add it to the tree (or `collect_decrypt_blobs.py` again), rebuild.
* AVB failure -> the image was modified after the build, or the footer is absent: do not hand-edit images; rebuild.
* `kernel identical` fails while the tree is right -> the build used another kernel variable (`FOX_OWN_KERNEL`, `FOX_DEBUG_KERNEL`): `build_fox.sh` prints the variant it built.

## 5. What static checks cannot tell you
Whether it boots, whether the display and touch work, whether decryption succeeds on the user's phone, and whether the failure rate of a flaky kernel changed. State that in the release notes (`shipping.md`) and give the user one test to run (`orangefox-fbe-recovery-port/references/test-ladder-and-safety.md`).
