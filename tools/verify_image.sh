#!/bin/bash
# Static verification of a built toco recovery image (header, AVB footer, kernel/dtb identical to prebuilt/,
# ramdisk identical to the device tree, decrypt stack present or absent).
#   usage: [FOX_ROOT=~/fox_12.1] verify_image.sh <image> <label> <expect-crypto: yes|no>
set -u
IMG="$1"; LABEL="$2"; CRYPTO="$3"
S="${TMPDIR:-/tmp}"
FOX="${FOX_ROOT:-$HOME/fox_12.1}"   # the OrangeFox 12.1 source tree the image was built from
W="$S/verify_$LABEL"; rm -rf "$W"; mkdir -p "$W/u" "$W/rd"
ok=0; bad=0
chk() { if [ "$2" = "1" ]; then echo "  PASS  $1"; ok=$((ok+1)); else echo "  FAIL  $1"; bad=$((bad+1)); fi; }

echo "=== $LABEL: $IMG"
python3 -I $FOX/system/tools/mkbootimg/unpack_bootimg.py --boot_img "$IMG" --out "$W/u" > "$W/hdr.txt" 2>&1
grep -E "header version|kernel_size|ramdisk size|dtb size|recovery dtbo size|command line" "$W/hdr.txt" | cut -c1-330
P=$FOX/device/xiaomi/toco/prebuilt
cmp -s "$W/u/kernel" $P/Image.gz        && chk "kernel identical to prebuilt/Image.gz" 1 || chk "kernel identical to prebuilt/Image.gz" 0
cmp -s "$W/u/dtb" $P/dtb                && chk "dtb identical to prebuilt/dtb" 1 || chk "dtb identical to prebuilt/dtb" 0
cmp -s "$W/u/recovery_dtbo" $P/dtbo.img && chk "recovery dtbo identical to prebuilt/dtbo.img" 1 || chk "recovery dtbo identical to prebuilt/dtbo.img" 0
[ "$(stat -c%s "$IMG")" = "134217728" ] && chk "image is exactly 134217728 bytes" 1 || chk "image is exactly 134217728 bytes" 0
grep -q "boot image header version: 2" "$W/hdr.txt" && chk "boot header v2" 1 || chk "boot header v2" 0
grep -q "panic=0" "$W/hdr.txt" && chk "cmdline has panic=0" 1 || chk "cmdline has panic=0" 0
grep -q "androidboot.usbcontroller=a600000.dwc3" "$W/hdr.txt" && chk "cmdline has usbcontroller" 1 || chk "cmdline has usbcontroller" 0

cp "$IMG" "$W/recovery.img"
( cd "$W" && python3 -I $FOX/external/avb/avbtool.py verify_image --image recovery.img > avb.txt 2>&1 );
grep -q "Successfully verified sha256 hash" "$W/avb.txt" && chk "AVB footer: hash + signature verify" 1 || chk "AVB footer: hash + signature verify" 0

( cd "$W/rd" && gzip -dc "$W/u/ramdisk" | cpio -idm --quiet 2>/dev/null )
R="$W/rd"
grep -q "start health-hal-2-1" "$R/init.recovery.qcom.rc" && chk "init: starts health-hal-2-1" 1 || chk "init: starts health-hal-2-1" 0
[ -f "$R/ueventd.qcom.rc" ] && chk "ueventd.qcom.rc present" 1 || chk "ueventd.qcom.rc present" 0
grep -q "mounttodecrypt" "$R/system/etc/twrp.flags" && chk "twrp.flags: /firmware mounttodecrypt" 1 || chk "twrp.flags: /firmware mounttodecrypt" 0
strings -n 8 "$R/system/bin/recovery" | grep -q "GUI did not start" && chk "recovery binary has the hold-on-GUI-failure code" 1 || chk "recovery binary has the hold-on-GUI-failure code" 0
# every file of the device tree's recovery/root must be in the ramdisk, byte for byte
T=$FOX/device/xiaomi/toco/recovery/root
miss=0; diffs=0
while IFS= read -r f; do
  rel="${f#$T/}"
  if [ ! -e "$R/$rel" ]; then miss=$((miss+1)); echo "    missing in image: $rel"
  elif ! cmp -s "$f" "$R/$rel"; then diffs=$((diffs+1)); echo "    differs in image: $rel"; fi
done < <(find "$T" -type f)
[ "$miss" = 0 ] && [ "$diffs" = 0 ] && chk "device-tree recovery/root files all present and identical in the ramdisk" 1 || chk "device-tree recovery/root files all present and identical in the ramdisk" 0
# nothing stale in vendor/lib64 (files that were removed from the tree must not survive in the staging dir)
stale=0
for f in $(cd "$R/vendor/lib64" 2>/dev/null && find . -type f | sed 's#^\./##'); do
  [ -e "$T/vendor/lib64/$f" ] || { stale=$((stale+1)); echo "    stale in image (not in tree): vendor/lib64/$f"; }
done
[ "$stale" = 0 ] && chk "no stale files in the image's vendor/lib64" 1 || chk "no stale files in the image's vendor/lib64" 0
[ -x "$R/system/bin/fox_decrypt_diag.sh" ] && chk "fox_decrypt_diag.sh is executable in the image" 1 || chk "fox_decrypt_diag.sh is executable in the image" 0
grep -q "/vendor/firmware_mnt" "$R/init.recovery.qcom.rc" && grep -q "service fox_diag_run" "$R/init.recovery.qcom.rc" && chk "init: firmware mount + diag services present" 1 || chk "init: firmware mount + diag services present" 0
if [ "$CRYPTO" = "yes" ]; then
  strings -n 8 "$R/system/bin/recovery" | grep -q "Decrypt: waiting for the decryption services" && chk "recovery binary has the bounded metadata decrypt" 1 || chk "recovery binary has the bounded metadata decrypt" 0
  strings -n 8 "$R/system/bin/recovery" | grep -q "Successfully decrypted metadata encrypted data partition" && chk "recovery built WITH metadata decrypt (log string present)" 1 || chk "recovery built WITH metadata decrypt (log string present)" 0
fi
if [ "$CRYPTO" = "yes" ]; then
  [ -f "$R/init.recovery.qcom_decrypt.rc" ] && chk "decrypt init rc generated" 1 || chk "decrypt init rc generated" 0
  grep -q "service qseecomd" "$R/init.recovery.qcom_decrypt.rc" 2>/dev/null && chk "qseecomd service defined" 1 || chk "qseecomd service defined" 0
  grep -q "keymaster-4-1-qti" "$R/init.recovery.qcom_decrypt.rc" 2>/dev/null && chk "keymaster-4-1-qti service defined" 1 || chk "keymaster-4-1-qti service defined" 0
  python3 -I "$(dirname "$0")/verify_ramdisk.py" "$R" > "$W/deps.txt" 2>&1 && chk "decrypt-stack library closure complete" 1 || { chk "decrypt-stack library closure complete" 0; cat "$W/deps.txt"; }
else
  [ ! -f "$R/init.recovery.qcom_decrypt.rc" ] && chk "no decrypt init rc (nocrypt)" 1 || chk "no decrypt init rc (nocrypt)" 0
  grep -rq "service qseecomd" "$R"/*.rc "$R"/system/etc/init 2>/dev/null && chk "no qseecomd service anywhere (nocrypt)" 0 || chk "no qseecomd service anywhere (nocrypt)" 1
  strings -n 8 "$R/system/bin/recovery" | grep -q "Metadata FBE decrypt support not present" && echo "  note  recovery has the 'metadata decrypt not present' message (expected: crypto compiled out)"
  strings -n 8 "$R/system/bin/recovery" | grep -qE "ro.crypto.fs_crypto_blkdev|fscrypt_mount_metadata_encrypted" && echo "  note  crypto strings still present in recovery binary" || echo "  note  no crypto strings in recovery binary"
fi
echo "  ----  $ok passed, $bad failed"
echo "  sha256 $(sha256sum "$IMG" | cut -d' ' -f1)"
