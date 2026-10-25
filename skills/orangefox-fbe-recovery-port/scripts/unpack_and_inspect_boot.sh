#!/usr/bin/env bash
#
# unpack_and_inspect_boot.sh - unpack a boot / recovery / vendor_boot image and translate the header into the lines a
# recovery device tree needs (BoardConfig.mk and device.conf). Read-only on the image.
#
#   unpack_and_inspect_boot.sh IMAGE [OUTDIR]
#
# Needs AOSP's unpack_bootimg.py (system/tools/mkbootimg). It is found in this order: $UNPACK_BOOTIMG, then
# $FOX_ROOT/system/tools/mkbootimg/unpack_bootimg.py (the OrangeFox tree), then unpack_bootimg / unpack_bootimg.py in PATH.
# Without any: https://android.googlesource.com/platform/system/tools/mkbootimg/+/refs/heads/main/unpack_bootimg.py
#
# Typical uses
#  * the stock recovery (or boot) image of the device: offsets, page size, header version, command line  -> device.conf [boot]
#  * the boot.img of the ROM whose /data must be read: its kernel (and dtb) become the recovery's kernel  -> prebuilt/
#    (kernel, dtb and recovery_dtbo end up in OUTDIR; dtbo can also be dumped from the dtbo partition with dd)
set -u
IMG="${1:-}"
OUT="${2:-}"
[ -f "$IMG" ] || { sed -n '2,16p' "$0"; exit 2; }
[ -n "$OUT" ] || OUT="$(mktemp -d "${TMPDIR:-/tmp}/bootimg.XXXXXX")"
mkdir -p "$OUT"

UB="${UNPACK_BOOTIMG:-}"
[ -n "$UB" ] || { [ -n "${FOX_ROOT:-}" ] && [ -f "$FOX_ROOT/system/tools/mkbootimg/unpack_bootimg.py" ] && UB="$FOX_ROOT/system/tools/mkbootimg/unpack_bootimg.py"; }
[ -n "$UB" ] || UB="$(command -v unpack_bootimg 2>/dev/null || command -v unpack_bootimg.py 2>/dev/null || true)"
[ -n "$UB" ] || { echo "unpack_bootimg.py not found: set UNPACK_BOOTIMG or FOX_ROOT (see the header of this script)" >&2; exit 2; }
case "$UB" in *.py) UBRUN=(python3 -I "$UB") ;; *) UBRUN=("$UB") ;; esac

echo "== image: $IMG ($(wc -c < "$IMG") bytes), unpacked into $OUT"
"${UBRUN[@]}" --boot_img "$IMG" --out "$OUT" > "$OUT/header.txt" 2>&1 || { cat "$OUT/header.txt"; exit 1; }
cat "$OUT/header.txt"
MK="$("${UBRUN[@]}" --boot_img "$IMG" --out "$OUT/.again" --format mkbootimg 2>/dev/null | tr -d '\n')"

val() { sed -n "s/^$1: *//p" "$OUT/header.txt" | head -1; }
mk()  { printf '%s' "$MK" | sed -n "s/.*--$1 \\([^ ]*\\).*/\\1/p"; }

echo
echo "== compression"
magic() { od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n'; }
for f in kernel ramdisk; do
    [ -s "$OUT/$f" ] || continue
    m="$(magic "$OUT/$f")"
    case "$m" in
        1f8b*) c="gzip" ;;
        5d00*) c="lzma" ;;
        04224d18) c="lz4 (frame)" ;;
        02214c18) c="lz4 (legacy)" ;;
        fd377a58) c="xz" ;;
        28b52ffd) c="zstd" ;;
        425a68*) c="bzip2" ;;
        30373037) c="cpio (uncompressed)" ;;
        *) c="raw / unknown (magic $m)" ;;
    esac
    echo "$f: $c"
done
if [ -s "$OUT/kernel" ] && [ "$(magic "$OUT/kernel")" != "" ]; then
    case "$(magic "$OUT/kernel")" in
        1f8b*) v="$(gzip -dc "$OUT/kernel" 2>/dev/null | strings -n 12 | grep -m1 'Linux version')" ;;
        *)     v="$(strings -n 12 "$OUT/kernel" | grep -m1 'Linux version')" ;;
    esac
    echo "kernel version string: ${v:-not found}"
fi
[ -s "$OUT/dtb" ] && echo "separate dtb: $(wc -c < "$OUT/dtb") bytes (header v2: use TARGET_PREBUILT_DTB)  [no separate dtb + a kernel named Image.gz-dtb means the dtb is appended to the kernel]"
[ -s "$OUT/recovery_dtbo" ] && echo "recovery_dtbo: $(wc -c < "$OUT/recovery_dtbo") bytes (header v1/v2: BOARD_PREBUILT_DTBOIMAGE + BOARD_INCLUDE_RECOVERY_DTBO)"

echo
echo "== device.conf lines  [boot]"
hv="$(val 'boot image header version')"
echo "BOOT_HEADER_VERSION=${hv:-?}"
echo "PAGESIZE=$(( $(mk pagesize) ))"
echo "KERNEL_BASE=$(mk base)"
echo "KERNEL_OFFSET=$(mk kernel_offset)"
echo "RAMDISK_OFFSET=$(mk ramdisk_offset)"
so="$(mk second_offset)"; [ "$(val 'second bootloader size')" = "0" ] && so="0x00f00000   # no second stage in this image: keep the usual default"
echo "SECOND_OFFSET=$so"
echo "TAGS_OFFSET=$(mk tags_offset)"
dto="$(mk dtb_offset)"; [ -n "$dto" ] && echo "DTB_OFFSET=$dto"
echo "KERNEL_CMDLINE=\"$(val 'command line args')\""
echo "# additional command line (extra_cmdline): $(val 'additional command line args')"
case "${hv:-}" in
    3|4) echo "NOTE: header v$hv - the recovery of such a device lives in the ramdisk of boot/vendor_boot; the template supports v0-v2 images with a dedicated recovery partition only. Unpack vendor_boot too, and read device-tree-guide.md ('A/B and recovery-in-boot')." ;;
esac
echo
echo "Trim the command line before using it: drop what the bootloader adds per boot or per device (androidboot.serialno, androidboot.bootloader,"
echo "androidboot.verifiedbootstate, androidboot.slot_suffix, bootconfig items, root=, buildvariant=). Keep console/earlycon, androidboot.hardware,"
echo "androidboot.usbcontroller, androidboot.dynamic_partitions=true and any option the stock recovery needs. Compare with /proc/cmdline of the stock recovery"
echo "booted on the phone: what the bootloader appends there does not belong in BoardConfig."
echo
echo "partition size: not in the image. On the phone:  adb shell cat /sys/class/block/\$(basename \$(readlink -f /dev/block/bootdevice/by-name/recovery))/size"
echo "(512-byte sectors; times 512 = bytes)  or  fastboot getvar partition-size:recovery"
