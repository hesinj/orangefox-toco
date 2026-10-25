#!/usr/bin/env bash
#
# kernel_marker_check.sh - does this kernel image understand what a modern encrypted /data needs?
#
#   kernel_marker_check.sh KERNEL [KERNEL ...]        (Image, Image.gz, or the kernel file of unpack_bootimg; gzip is detected)
#
# It looks for plain strings that only exist in a kernel built with a feature (option names of the file systems, device-mapper
# targets, key type names). Quick yes/no, not proof: a feature can be present and still misbehave, and a kernel without kallsyms
# strings may hide a marker. The markers were checked on the reference port: the stock MIUI 4.14.117 kernel of the Mi Note 10 Lite
# had none of them except a trace of "default-key"; the PixelOS 4.14.356 kernel has all of them.
#
#   fscrypt-provisioning   keyring key type of fscrypt policy v2 (FS_IOC_ADD_ENCRYPTION_KEY era)
#   wrappedkey_v0          hardware-wrapped keys (dm-default-key / inline crypto with a key the kernel never sees)
#   dm-default-key         the device-mapper target of metadata encryption
#   inlinecrypt            the f2fs/ext4 mount option for inline encryption (UFS ICE)
#   blk-crypto             the block-layer inline-encryption framework
#   compress_algorithm     f2fs compression (userdata with compress_extension= / fscompress)
#   erofs                  read-only EROFS (logical partitions of recent ROMs)
#   fs-verity              fs-verity (not needed for decryption; recent ROMs use it)
set -u
[ $# -ge 1 ] || { sed -n '2,20p' "$0"; exit 2; }
MARKERS=("fscrypt-provisioning" "wrappedkey_v0" "dm-default-key" "inlinecrypt" "blk-crypto" "compress_algorithm" "erofs" "fs-verity")
NEED_FBE_V2=("fscrypt-provisioning")
TMP="$(mktemp -d "${TMPDIR:-/tmp}/kmark.XXXXXX")"
i=0
for K in "$@"; do
    i=$((i + 1))
    RAW="$TMP/k$i.bin"
    if [ "$(od -An -tx1 -N2 "$K" | tr -d ' \n')" = "1f8b" ]; then gzip -dc "$K" > "$RAW" 2>/dev/null; else cp "$K" "$RAW"; fi
    strings -n 8 "$RAW" | sort -u > "$TMP/k$i.str"
    echo "== $K"
    ver="$(grep -a -m1 -E 'Linux version [0-9]' "$TMP/k$i.str" | cut -c1-140)"
    echo "   ${ver:-no 'Linux version' banner found}"
    for m in "${MARKERS[@]}"; do
        n=$(grep -a -c -F -- "$m" "$TMP/k$i.str")
        printf '   %-22s %s\n' "$m" "$([ "$n" -gt 0 ] && echo "present ($n strings)" || echo "ABSENT")"
    done
    v2=$(grep -a -c -F "fscrypt-provisioning" "$TMP/k$i.str")
    wk=$(grep -a -c -F "wrappedkey_v0" "$TMP/k$i.str")
    dk=$(grep -a -c -F "dm-default-key" "$TMP/k$i.str")
    ic=$(grep -a -c -F "inlinecrypt" "$TMP/k$i.str")
    if [ "$v2" -gt 0 ] && [ "$wk" -gt 0 ] && [ "$dk" -gt 0 ] && [ "$ic" -gt 0 ]; then
        echo "   -> looks able to read FBE v2 + metadata encryption + hardware-wrapped keys"
    elif [ "$v2" -gt 0 ] && [ "$dk" -gt 0 ]; then
        echo "   -> FBE v2 and metadata encryption yes; hardware-wrapped keys / inline crypto markers missing: fine only if the fstab has no wrappedkey / inlinecrypt"
    elif [ "$v2" -gt 0 ]; then
        echo "   -> FBE v2 yes, no metadata-encryption target: fine only for userdata without metadata_encryption="
    else
        echo "   -> NOT able to read a modern FBE v2 userdata: use the kernel of the ROM whose /data you want to read"
    fi
done
echo
echo "files kept in $TMP (decompressed kernels and their strings)"
