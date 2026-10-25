#!/bin/bash
# Build the two release variants of a device (with and without the decryption stack) and collect them under a tag.
#   usage: run_release.sh DEVICE TAG [OUTDIR]
#   Result in OUTDIR (default ./deliverables_TAG): <image name>-TAG.img / .zip for both variants, build logs, SHA256SUMS.
# The image names are the ones the OrangeFox build produces: OrangeFox-R12.0-Unofficial-DEVICE.* (full),
# OrangeFox-R12.0_nocrypt-Unofficial-DEVICE.* (nocrypt). Releasing both is deliberate: the nocrypt twin is the control
# image of every bug hunt (see recovery-boot-debugging).
DEVICE="${1:?usage: run_release.sh DEVICE TAG [OUTDIR]}"; TAG="${2:?tag}"
FOX="${FOX:-$HOME/fox_12.1}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${3:-$PWD/deliverables_$TAG}"
P="$FOX/out/target/product/$DEVICE"
mkdir -p "$OUT"
for v in full nocrypt; do
  echo "=== $(date +%T) building release $v ($TAG)"
  log="$OUT/build_${TAG}_$v.log"
  FOX="$FOX" "$HERE/build_fox.sh" "$DEVICE" "$v" > "$log" 2>&1
  if ! grep -q FOX_BUILD_OK "$log"; then
    echo "BUILD FAILED for $v"; grep -n "error:" "$log" | head; tail -15 "$log"; exit 1
  fi
  for ext in img zip; do
    for f in "$P"/OrangeFox*-"$DEVICE".$ext; do
      [ -f "$f" ] || continue
      case "$(basename "$f")" in *nocrypt*) is=nocrypt ;; *) is=full ;; esac
      [ "$is" = "$v" ] || continue
      b="$(basename "$f" ".$ext")"
      cp --sparse=always "$f" "$OUT/$b-$TAG.$ext" && echo "copied $b-$TAG.$ext"
    done
  done
done
( cd "$OUT" && sha256sum ./*.img ./*.zip > SHA256SUMS && cat SHA256SUMS )
echo "RELEASE_${TAG}_DONE"
