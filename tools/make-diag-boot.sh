#!/bin/bash
# Repack a ROM's own boot image for a diagnostic boot with `fastboot boot` (nothing is written to the phone).
#   usage: [WARM=1] make-diag-boot.sh BOOT_IMG OUT_IMG [EXTRA_CMDLINE]
#   BOOT_IMG        the boot image of the installed ROM (the release file, or a dump of the partition)
#   OUT_IMG         the image to write (without AVB footer: `fastboot boot` of an unlocked phone does not need one)
#   EXTRA_CMDLINE   appended to the image's own command line; default makes a panic or a lockup freeze the phone with the
#                   console still in RAM (pstore), instead of restarting it:
#                   panic=0 softlockup_panic=1 hung_task_panic=1 hung_task_timeout_secs=120
#   WARM=1          also add the property `qcom,force-warm-reboot` to the node `qcom,pshold` of the dtb (needs dtc's fdtput and
#                   dtc). Then EVERY restart the kernel performs, `reboot`, `reboot bootloader`, init's reboot after a service that
#                   was marked reboot_on_failure, is a warm reset and the pstore console survives it. Without it only a kernel
#                   panic is warm (msm_restart_prepare in msm-poweroff.c: on a phone whose PMIC node has qcom,store-hard-reset-reason
#                   every other restart is a hard reset that wipes the RAM). It changes nothing while the phone runs.
#   KERNEL=FILE     use this kernel (Image or Image.gz) instead of the image's own, e.g. a debug kernel with SLUB debugging
#   RAMDISK=FILE    use this ramdisk instead of the image's own
#   FOX             the OrangeFox tree that provides mkbootimg.py and unpack_bootimg.py (default ~/fox_12.1)
# Kernel and ramdisk stay byte-identical to the original unless KERNEL/RAMDISK name another file (then they must equal that file),
# and so does the dtb, except with WARM=1: then the only difference is one added property per qcom,pshold node (checked by
# decompiling both). Everything is checked at the end; a failed check removes OUT_IMG.
set -e
IN="${1:?usage: make-diag-boot.sh BOOT_IMG OUT_IMG [EXTRA_CMDLINE]}"; OUT="${2:?OUT_IMG}"
EXTRA="${3-panic=0 softlockup_panic=1 hung_task_panic=1 hung_task_timeout_secs=120}"
FOX="${FOX:-$HOME/fox_12.1}"
MB="$FOX/system/tools/mkbootimg"
[ -f "$MB/unpack_bootimg.py" ] || { echo "no mkbootimg tools in $MB: set FOX to the OrangeFox tree (FOX=/path/to/fox_12.1) or to any AOSP tree that has system/tools/mkbootimg" >&2; exit 2; }
W="$(mktemp -d "${TMPDIR:-/tmp}/diagboot.XXXXXX")"
python3 -I "$MB/unpack_bootimg.py" --boot_img "$IN" --out "$W/u" --format=mkbootimg > "$W/args.txt"
WARMDTB=""
if [ "${WARM:-0}" = 1 ]; then
  [ -f "$W/u/dtb" ] || { echo "WARM=1: this image has no dtb section (boot header version below 2), nothing to patch" >&2; exit 2; }
  for t in fdtput dtc; do command -v "$t" > /dev/null || { echo "WARM=1 needs $t (package device-tree-compiler)" >&2; exit 2; }; done
  python3 -I - "$W/u/dtb" "$W/dtb.warm" <<'PY'
# Add `qcom,force-warm-reboot` to every node whose compatible is qcom,pshold, in every dtb that the image carries
# (a boot image of this generation holds one dtb or several of them one after the other).
import struct, subprocess, sys
src, dst = sys.argv[1], sys.argv[2]
PROP = "qcom,force-warm-reboot"
def nodes(b):
    """return [path, property names, compatible strings] for every node of one dtb"""
    off_struct, off_strings = struct.unpack_from(">II", b, 8)
    pos, names, open_nodes, out = off_struct, [], [], []
    while True:
        tok = struct.unpack_from(">I", b, pos)[0]; pos += 4
        if tok == 1:
            end = b.index(b"\0", pos); names.append(b[pos:end].decode()); pos = (end + 4) & ~3
            open_nodes.append(["/" + "/".join(names[1:]), set(), []]); out.append(open_nodes[-1])
        elif tok == 3:
            ln, nameoff = struct.unpack_from(">II", b, pos); pos += 8
            data = b[pos:pos + ln]; pos = (pos + ln + 3) & ~3
            name = b[off_strings + nameoff:b.index(b"\0", off_strings + nameoff)].decode()
            open_nodes[-1][1].add(name)
            if name == "compatible":
                open_nodes[-1][2] = [x.decode() for x in data.split(b"\0") if x]
        elif tok == 2:
            names.pop(); open_nodes.pop()
        elif tok == 9:
            return out
d = open(src, "rb").read()
res, pos, count = [], 0, 0
while pos < len(d):
    if d[pos:pos + 4] != b"\xd0\x0d\xfe\xed":
        sys.exit("dtb: unexpected data at offset %d" % pos)
    size = struct.unpack_from(">I", d, pos + 4)[0]
    blob = d[pos:pos + size]; pos += size
    todo = [p for p, props, comp in nodes(blob) if "qcom,pshold" in comp and PROP not in props]
    for p in todo:
        open(dst + ".tmp", "wb").write(blob)
        subprocess.run(["fdtput", dst + ".tmp", p, PROP], check=True)
        blob = open(dst + ".tmp", "rb").read(); count += 1
        print("dtb blob %d: added %s to %s" % (len(res), PROP, p), file=sys.stderr)
    res.append(blob)
if not count:
    sys.exit("no qcom,pshold node without %s found in the dtb: nothing patched" % PROP)
open(dst, "wb").write(b"".join(res))
PY
  WARMDTB="$W/dtb.warm"
fi
for f in "${KERNEL:-}" "${RAMDISK:-}"; do [ -z "$f" ] || [ -f "$f" ] || { echo "no such file: $f" >&2; exit 2; }; done
python3 -I - "$W/args.txt" "$EXTRA" "$MB/mkbootimg.py" "$OUT" "$WARMDTB" "${KERNEL:-}" "${RAMDISK:-}" > "$W/run.sh" <<'PY'
import shlex, sys
args = shlex.split(open(sys.argv[1]).read())
extra, mkb, out, warmdtb, kernel, ramdisk = sys.argv[2:8]
i = args.index("--cmdline")
args[i + 1] = (args[i + 1] + " " + extra).strip()
if warmdtb:
    args[args.index("--dtb") + 1] = warmdtb
if kernel:
    args[args.index("--kernel") + 1] = kernel
if ramdisk:
    args[args.index("--ramdisk") + 1] = ramdisk
print("python3 -I " + shlex.quote(mkb) + " " + " ".join(shlex.quote(a) for a in args) + " --output " + shlex.quote(out))
PY
bash "$W/run.sh"
python3 -I "$MB/unpack_bootimg.py" --boot_img "$OUT" --out "$W/v" > "$W/v.txt"
for f in kernel ramdisk dtb; do
  [ -e "$W/u/$f" ] || continue
  if [ "$f" = dtb ] && [ -n "$WARMDTB" ]; then
    python3 -I - "$W/u/dtb" "$W/v/dtb" "$W" <<'PY' || { rm -f "$OUT"; exit 1; }
# Decompile every dtb of the image before and after and show that the only difference is the added property.
import difflib, struct, subprocess, sys
def blobs(path):
    d = open(path, "rb").read(); out = []; pos = 0
    while pos < len(d):
        size = struct.unpack_from(">I", d, pos + 4)[0]; out.append(d[pos:pos + size]); pos += size
    return out
def dts(blob, work):
    open(work + "/blob.dtb", "wb").write(blob)
    return subprocess.run(["dtc", "-I", "dtb", "-O", "dts", "-q", work + "/blob.dtb"], capture_output=True, text=True).stdout.splitlines()
old, new, work = blobs(sys.argv[1]), blobs(sys.argv[2]), sys.argv[3]
if len(old) != len(new):
    sys.exit("dtb: %d dtbs in the original, %d in the new image" % (len(old), len(new)))
added = 0
for i, (o, n) in enumerate(zip(old, new)):
    extra = [l for l in difflib.unified_diff(dts(o, work), dts(n, work), lineterm="", n=0) if l[:1] in "+-" and l[:3] not in ("+++", "---")]
    bad = [l for l in extra if not (l[0] == "+" and l[1:].strip() == "qcom,force-warm-reboot;")]
    if bad:
        sys.exit("dtb %d differs from the original by more than the added property:\n%s" % (i, "\n".join(bad[:10])))
    added += len(extra)
print("dtb: %d dtb(s) in the image; the only difference is %d added property qcom,force-warm-reboot (every restart is warm)" % (len(old), added))
PY
    continue
  fi
  ORIG="$W/u/$f"; WHAT="the original"
  if [ "$f" = kernel ] && [ -n "${KERNEL:-}" ]; then ORIG="$KERNEL"; WHAT="the file you gave"; fi
  if [ "$f" = ramdisk ] && [ -n "${RAMDISK:-}" ]; then ORIG="$RAMDISK"; WHAT="the file you gave"; fi
  cmp -s "$ORIG" "$W/v/$f" && echo "$f: identical to $WHAT" || { echo "$f: DIFFERS from $WHAT"; rm -f "$OUT"; exit 1; }
done
grep -E "command line args" "$W/v.txt" | cut -c1-400
ls -l "$OUT"
echo "DIAG_BOOT_OK  (boot it with:  fastboot boot $OUT)"
