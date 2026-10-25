#!/usr/bin/env bash
#
# compare_kernel_strings.sh - are two kernel images the same source and configuration? Compare what they print, not what they claim.
#
#   compare_kernel_strings.sh KERNEL_A KERNEL_B [OUTDIR]       (Image, Image.gz, or the kernel file of unpack_bootimg)
#
# Why: the kernel configuration embedded in a prebuilt kernel (IKCONFIG, /proc/config.gz) can be a stale blob. On the reference port both
# the vendor's kernel and our own build carried the same "4.14.180" config that described neither of them, so "721 options differ" was a
# false finding. The readable strings are the honest signal: every printk format string, option name, device-tree property name and
# driver message is in the image, and a feature that is compiled in leaves strings behind.
#
# Output: counts, the strings only in A, only in B (files in OUTDIR), and the banner lines (compiler, linker, build time). For two builds
# of the same source with different compilers expect a handful of differences (12 and 4 messages out of about 18200 on the reference port:
# the version banner, a few format strings the compilers fold differently).
set -u
A="${1:-}"; B="${2:-}"
[ -f "$A" ] && [ -f "$B" ] || { sed -n '2,16p' "$0"; exit 2; }
OUT="${3:-$(mktemp -d "${TMPDIR:-/tmp}/kcmp.XXXXXX")}"; mkdir -p "$OUT"
prep() { # $1 image  $2 label
    if [ "$(od -An -tx1 -N2 "$1" | tr -d ' \n')" = "1f8b" ]; then gzip -dc "$1" > "$OUT/$2.bin" 2>/dev/null; else cp "$1" "$OUT/$2.bin"; fi
    strings -n 8 "$OUT/$2.bin" | sort -u > "$OUT/$2.str"
    # readable messages only: raw strings(1) output is full of code bytes that differ with every compiler
    grep -a -E '^[A-Za-z%<(][]A-Za-z0-9 _.:,;%()=<>/+*#!?@[-]{11,}$' "$OUT/$2.str" | grep -a -E '[A-Za-z]{3,} [A-Za-z%]' > "$OUT/$2.msg"
}
prep "$A" a; prep "$B" b
echo "A: $A  ($(wc -c < "$OUT/a.bin") bytes unpacked, $(wc -l < "$OUT/a.str") distinct strings, $(wc -l < "$OUT/a.msg") readable messages)"
echo "B: $B  ($(wc -c < "$OUT/b.bin") bytes unpacked, $(wc -l < "$OUT/b.str") distinct strings, $(wc -l < "$OUT/b.msg") readable messages)"
comm -23 "$OUT/a.msg" "$OUT/b.msg" > "$OUT/only-a.txt"
comm -13 "$OUT/a.msg" "$OUT/b.msg" > "$OUT/only-b.txt"
echo "messages only in A: $(wc -l < "$OUT/only-a.txt")   only in B: $(wc -l < "$OUT/only-b.txt")   (lists in $OUT/only-a.txt, only-b.txt)"
echo
echo "== banners"
for l in a b; do echo "[$l]"; grep -a -m2 -E 'Linux version [0-9]' "$OUT/$l.str" | cut -c1-260; done
echo
echo "== messages only in A (first 25)"; head -n 25 "$OUT/only-a.txt" | cut -c1-160
echo "== messages only in B (first 25)"; head -n 25 "$OUT/only-b.txt" | cut -c1-160
echo
echo "Reading: a handful of differences (banner, folded format strings) = same source and configuration."
echo "Hundreds of differences in driver/file-system messages = a different configuration or source. For symbol-level comparison:"
echo "  pip install vmlinux-to-elf; vmlinux-to-elf KERNEL out.elf; then compare 'nm' / kallsyms of the two (kernel with kallsyms only)."
