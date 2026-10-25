#!/bin/bash
# Static verification of a built recovery image, before anybody boots it: boot header, size, AVB footer, kernel/dtb against the
# files the device tree ships, ramdisk against the device tree's recovery/root (nothing missing, nothing stale), VINTF manifest,
# decryption stack present or absent, library closure of the decryption services.
#   usage: [FOX_ROOT=~/fox_12.1] [DEVICE_DIR=<fox>/device/<oem>/<dev>] verify_image.sh <image> <label> <yes|no>
#     <yes|no>   whether the image is meant to carry the decryption stack (yes = full, no = nocrypt twin)
#   optional environment:
#     PARTITION_SIZE   expected image size in bytes (default: BOARD_RECOVERYIMAGE_PARTITION_SIZE from DEVICE_DIR/BoardConfig.mk, else not checked)
#     KERNEL_REF DTB_REF DTBO_REF   files the image's kernel / dtb / recovery_dtbo must equal byte for byte (default: first match in DEVICE_DIR/prebuilt)
#     KERNEL_SHA256    the image's kernel must have this sha256 (use it when the kernel is a vendor/ROM binary that must stay untouched)
#     EXPECT_PANIC0    yes|no   require / forbid panic=0 on the command line (default: not checked)
#     FORBID_CMDLINE   extended regex that must NOT match the command line (e.g. 'kasan|slub_debug|retain_initrd' for a release)
#     STRICT_STALE     yes: files in the image's vendor/{lib,lib64,bin,etc} that are not in the device tree fail the check (default: warn)
# The last lines: "N passed, M failed" and the image's sha256. Exit status 1 when anything failed.
set -u
IMG="${1:?usage: verify_image.sh <image> <label> <yes|no>}"; LABEL="${2:?label}"; CRYPTO="${3:?yes|no}"
S="${TMPDIR:-/tmp}"
FOX="${FOX_ROOT:-$HOME/fox_12.1}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DEV="${DEVICE_DIR:-}"
[ -n "$DEV" ] || { DEV="$(ls -d "$FOX"/device/*/*/ 2>/dev/null | head -1)"; DEV="${DEV%/}"; echo "note  DEVICE_DIR not set, using $DEV"; }
W="$S/verify_$LABEL"; mkdir -p "$W/u" "$W/rd"
find "$W" -mindepth 1 -maxdepth 1 -type d -name rd -exec rm -r {} + 2>/dev/null; mkdir -p "$W/rd"
ok=0; bad=0; warn=0
chk() { if [ "$2" = "1" ]; then echo "  PASS  $1"; ok=$((ok+1)); else echo "  FAIL  $1"; bad=$((bad+1)); fi; }
has() { grep -aq -- "$2" "$1" 2>/dev/null; }           # has FILE FIXED-STRING  (no strings(1) needed)

echo "=== $LABEL: $IMG"
python3 -I "$FOX/system/tools/mkbootimg/unpack_bootimg.py" --boot_img "$IMG" --out "$W/u" > "$W/hdr.txt" 2>&1 \
  || { echo "  FAIL  unpack_bootimg could not read the image"; cat "$W/hdr.txt"; exit 1; }
grep -E "header version|kernel_size|ramdisk size|dtb size|recovery dtbo size|os version|os patch level|command line" "$W/hdr.txt" | cut -c1-330

# --- size ---
PS="${PARTITION_SIZE:-}"
[ -n "$PS" ] || PS="$(sed -n 's/^[[:space:]]*BOARD_RECOVERYIMAGE_PARTITION_SIZE[[:space:]]*:\?=[[:space:]]*\([0-9x]*\).*/\1/p' "$DEV/BoardConfig.mk" 2>/dev/null | head -1)"
if [ -n "$PS" ]; then
  [ "$(stat -c%s "$IMG")" = "$((PS))" ] && chk "image is exactly $((PS)) bytes (the recovery partition size)" 1 || chk "image is exactly $((PS)) bytes (the recovery partition size)" 0
else echo "  note  partition size unknown (set PARTITION_SIZE): size not checked"; fi

# --- kernel / dtb / dtbo against the files the tree ships ---
first() { for f in "$@"; do [ -f "$f" ] && { echo "$f"; return; }; done; }
KR="${KERNEL_REF:-$(first "$DEV"/prebuilt/Image.gz "$DEV"/prebuilt/Image.gz-dtb "$DEV"/prebuilt/kernel "$DEV"/prebuilt/Image)}"
DR="${DTB_REF:-$(first "$DEV"/prebuilt/dtb "$DEV"/prebuilt/dtb.img)}"
OR="${DTBO_REF:-$(first "$DEV"/prebuilt/dtbo.img "$DEV"/prebuilt/dtbo)}"
if [ -n "$KR" ] && [ -f "$W/u/kernel" ]; then cmp -s "$W/u/kernel" "$KR" && chk "kernel identical to ${KR#$DEV/}" 1 || chk "kernel identical to ${KR#$DEV/}" 0; fi
if [ -n "${KERNEL_SHA256:-}" ] && [ -f "$W/u/kernel" ]; then
  [ "$(sha256sum "$W/u/kernel" | cut -d' ' -f1)" = "$KERNEL_SHA256" ] && chk "kernel sha256 is the expected one (vendor binary untouched)" 1 || chk "kernel sha256 is the expected one (vendor binary untouched)" 0
fi
if [ -n "$DR" ] && [ -f "$W/u/dtb" ]; then cmp -s "$W/u/dtb" "$DR" && chk "dtb identical to ${DR#$DEV/}" 1 || chk "dtb identical to ${DR#$DEV/}" 0; fi
if [ -n "$OR" ] && [ -f "$W/u/recovery_dtbo" ]; then cmp -s "$W/u/recovery_dtbo" "$OR" && chk "recovery dtbo identical to ${OR#$DEV/}" 1 || chk "recovery dtbo identical to ${OR#$DEV/}" 0; fi

# --- command line ---
case "${EXPECT_PANIC0:-}" in
  yes) grep -q "panic=0" "$W/hdr.txt" && chk "cmdline has panic=0 (a panic freezes instead of restarting, pstore keeps it)" 1 || chk "cmdline has panic=0 (a panic freezes instead of restarting, pstore keeps it)" 0 ;;
  no)  grep -q "panic=0" "$W/hdr.txt" && chk "cmdline has no panic=0 (release)" 0 || chk "cmdline has no panic=0 (release)" 1 ;;
esac
if [ -n "${FORBID_CMDLINE:-}" ]; then
  grep -E "command line" "$W/hdr.txt" | grep -Eq "$FORBID_CMDLINE" && chk "cmdline free of: $FORBID_CMDLINE" 0 || chk "cmdline free of: $FORBID_CMDLINE" 1
fi

# --- AVB footer (only when the image has one) ---
if has "$IMG" "AVBf"; then
  cp "$IMG" "$W/recovery.img"
  ( cd "$W" && python3 -I "$FOX/external/avb/avbtool.py" verify_image --image recovery.img > avb.txt 2>&1 )
  grep -q "Successfully verified" "$W/avb.txt" && chk "AVB footer: hash (and signature when signed) verify" 1 || { chk "AVB footer: hash (and signature when signed) verify" 0; tail -3 "$W/avb.txt"; }
else echo "  note  no AVB footer in the image"; fi

# --- ramdisk: unpack by magic ---
case "$(od -An -tx1 -N4 "$W/u/ramdisk" | tr -d ' \n')" in
  1f8b*)     DEC="gzip -dc" ;;
  5d00*)     DEC="lzma -dc" ;;
  fd377a58)  DEC="xz -dc" ;;
  28b52ffd)  DEC="zstd -dc" ;;
  04224d18|02214c18) DEC="lz4 -dc" ;;
  *)         DEC="cat"; echo "  note  unknown ramdisk compression" ;;
esac
( cd "$W/rd" && $DEC "$W/u/ramdisk" | cpio -idm --quiet 2>/dev/null )
R="$W/rd"
[ -x "$R/system/bin/recovery" ] || [ -x "$R/sbin/recovery" ] && chk "ramdisk has the recovery binary" 1 || chk "ramdisk has the recovery binary" 0
RB="$R/system/bin/recovery"; [ -f "$RB" ] || RB="$R/sbin/recovery"

# --- every file of the device tree's recovery/root must be in the ramdisk, byte for byte ---
T="$DEV/recovery/root"
if [ -d "$T" ]; then
  miss=0; diffs=0
  while IFS= read -r f; do
    rel="${f#$T/}"
    if [ ! -e "$R/$rel" ]; then miss=$((miss+1)); echo "    missing in image: $rel"
    elif ! cmp -s "$f" "$R/$rel"; then diffs=$((diffs+1)); echo "    differs in image: $rel"; fi
  done < <(find "$T" -type f)
  [ "$miss" = 0 ] && [ "$diffs" = 0 ] && chk "device-tree recovery/root files all present and identical in the ramdisk" 1 || chk "device-tree recovery/root files all present and identical in the ramdisk" 0
  # a file removed from the tree must not survive in out/target/product/<dev>/recovery/root (the staging dir is not cleaned between builds)
  stale=0
  for d in vendor/lib64 vendor/lib vendor/bin vendor/etc; do
    [ -d "$R/$d" ] || continue
    while IFS= read -r f; do
      [ -e "$T/$d/$f" ] || { stale=$((stale+1)); echo "    in image, not in the device tree: $d/$f"; }
    done < <(cd "$R/$d" && find . -type f | sed 's#^\./##')
  done
  if [ "$stale" = 0 ]; then chk "no unexpected files in the image's vendor/{lib,lib64,bin,etc}" 1
  elif [ "${STRICT_STALE:-}" = yes ]; then chk "no unexpected files in the image's vendor/{lib,lib64,bin,etc} ($stale)" 0
  else echo "  WARN  $stale file(s) in the image's vendor/ are not in the device tree (build-produced, or stale: delete out/target/product/<dev>/{root,recovery,fake_packages} and rebuild; STRICT_STALE=yes makes this fatal)"; warn=$((warn+1)); fi
else echo "  note  $T not found: ramdisk not compared with the device tree"; fi

# --- the framework VINTF manifest: without it libhidl will not hand out the HIDL service manager and keystore2 aborts at start-up ---
if [ "$CRYPTO" = yes ]; then
  { has "$R/system/etc/vintf/manifest.xml" "android.hidl.manager" && has "$R/system/etc/vintf/manifest.xml" "1.2"; } \
    && chk "framework VINTF manifest declares android.hidl.manager@1.2" 1 || chk "framework VINTF manifest declares android.hidl.manager@1.2" 0
fi

# --- decryption stack ---
RC="$(ls "$R"/init.recovery.*decrypt*.rc "$R"/system/etc/init/*decrypt*.rc 2>/dev/null | head -1)"
if [ "$CRYPTO" = yes ]; then
  has "$RB" "Successfully decrypted metadata encrypted data partition" && chk "recovery built WITH metadata decrypt (log string present)" 1 || chk "recovery built WITH metadata decrypt (log string present)" 0
  has "$RB" "Decrypt: waiting for the decryption services" && chk "recovery binary has the bounded metadata decrypt (startup-hardening patch)" 1 || chk "recovery binary has the bounded metadata decrypt (startup-hardening patch)" 0
  [ -n "$RC" ] && chk "decrypt init rc generated ($(basename "$RC"))" 1 || chk "decrypt init rc generated" 0
  python3 -I "$HERE/verify_ramdisk.py" "$R" > "$W/deps.txt" 2>&1 && chk "decryption services: library closure complete (verify_ramdisk.py)" 1 || { chk "decryption services: library closure complete (verify_ramdisk.py)" 0; cat "$W/deps.txt"; }
else
  [ -z "$RC" ] && chk "no decrypt init rc (nocrypt)" 1 || chk "no decrypt init rc (nocrypt): found $(basename "$RC")" 0
  grep -rqs "service qseecomd" "$R"/*.rc "$R"/system/etc/init 2>/dev/null && chk "no qseecomd service anywhere (nocrypt)" 0 || chk "no qseecomd service anywhere (nocrypt)" 1
  has "$RB" "fscrypt_mount_metadata_encrypted" && echo "  note  crypto strings still present in the recovery binary (the nocrypt build is meant to drop them)" || echo "  note  no metadata-decrypt code in the recovery binary"
fi
echo "  ----  $ok passed, $bad failed, $warn warning(s)"
echo "  sha256 $(sha256sum "$IMG" | cut -d' ' -f1)"
[ "$bad" = 0 ]
