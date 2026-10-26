#!/bin/sh
# Builds memstress for the phone (aarch64, static, no libc) and, if a host compiler exists, a host copy that runs a self test.
#   usage: build-memstress.sh [OUTDIR]        (default: the directory of this script)
#   CLANG   a clang that can target aarch64 and a linker (default: the one of the OrangeFox tree, else `clang` from PATH)
#   FOX     the OrangeFox tree (default ~/fox_12.1)
# Result: OUTDIR/memstress-aarch64 (push it to the phone with ram-test.bat), and "selftest passed" when the host copy detects an injected bit.
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE}"
FOX="${FOX:-$HOME/fox_12.1}"
CLANG="${CLANG:-}"
[ -n "$CLANG" ] || { [ -x "$FOX/prebuilts/clang/host/linux-x86/clang-r416183b/bin/clang" ] && CLANG="$FOX/prebuilts/clang/host/linux-x86/clang-r416183b/bin/clang" || CLANG=clang; }
CF="-O2 -ffreestanding -fno-builtin -fno-stack-protector -fno-pic -static -nostdlib -Wall"
echo "== aarch64 with $CLANG"
"$CLANG" --target=aarch64-linux-gnu $CF -fuse-ld=lld -Wl,-z,norelro -Wl,--build-id=none -o "$OUT/memstress-aarch64" "$HERE/memstress.c" || { echo "MEMSTRESS_BUILD_FAILED aarch64"; exit 1; }
ls -l "$OUT/memstress-aarch64"
if [ "$(uname -m)" = x86_64 ] && command -v gcc >/dev/null 2>&1; then
  echo "== host self test"
  gcc $CF -no-pie -Wno-unused-but-set-variable -o /tmp/memstress-host.$$ "$HERE/memstress.c" || { echo "MEMSTRESS_BUILD_FAILED host"; exit 1; }
  r="$(/tmp/memstress-host.$$ --seconds 6 1 2 --inject)"; rc=$?
  rm -f /tmp/memstress-host.$$
  echo "$r" | grep -q "failing bit positions: 17x1" && [ "$rc" = 2 ] && echo "selftest passed (the injected bit 17 was found, exit status 2)" || { echo "SELFTEST FAILED (exit $rc)"; echo "$r"; exit 1; }
fi
echo MEMSTRESS_BUILD_OK
