#!/bin/bash
# Repack a ROM's own boot image for a diagnostic boot with `fastboot boot` (nothing is written to the phone).
#   usage: make-diag-boot.sh BOOT_IMG OUT_IMG [EXTRA_CMDLINE]
#   BOOT_IMG        the boot image of the installed ROM (the release file, or a dump of the partition)
#   OUT_IMG         the image to write (without AVB footer: `fastboot boot` of an unlocked phone does not need one)
#   EXTRA_CMDLINE   appended to the image's own command line; default makes a panic or a lockup freeze the phone with the
#                   console still in RAM (pstore), instead of restarting it:
#                   panic=0 softlockup_panic=1 hung_task_panic=1 hung_task_timeout_secs=120
#   FOX             the OrangeFox tree that provides mkbootimg.py and unpack_bootimg.py (default ~/fox_12.1)
# Kernel, ramdisk and dtb stay byte-identical to the original (checked at the end); only the command line grows.
set -e
IN="${1:?usage: make-diag-boot.sh BOOT_IMG OUT_IMG [EXTRA_CMDLINE]}"; OUT="${2:?OUT_IMG}"
EXTRA="${3-panic=0 softlockup_panic=1 hung_task_panic=1 hung_task_timeout_secs=120}"
FOX="${FOX:-$HOME/fox_12.1}"
MB="$FOX/system/tools/mkbootimg"
W="$(mktemp -d "${TMPDIR:-/tmp}/diagboot.XXXXXX")"
python3 -I "$MB/unpack_bootimg.py" --boot_img "$IN" --out "$W/u" --format=mkbootimg > "$W/args.txt"
python3 -I - "$W/args.txt" "$EXTRA" "$MB/mkbootimg.py" "$OUT" > "$W/run.sh" <<'PY'
import shlex, sys
args = shlex.split(open(sys.argv[1]).read())
extra, mkb, out = sys.argv[2], sys.argv[3], sys.argv[4]
i = args.index("--cmdline")
args[i + 1] = (args[i + 1] + " " + extra).strip()
print("python3 -I " + shlex.quote(mkb) + " " + " ".join(shlex.quote(a) for a in args) + " --output " + shlex.quote(out))
PY
bash "$W/run.sh"
python3 -I "$MB/unpack_bootimg.py" --boot_img "$OUT" --out "$W/v" > "$W/v.txt"
for f in kernel ramdisk dtb; do
  [ -e "$W/u/$f" ] || continue
  cmp -s "$W/u/$f" "$W/v/$f" && echo "$f: identical to the original" || { echo "$f: DIFFERS from the original"; exit 1; }
done
grep -E "command line args" "$W/v.txt" | cut -c1-400
ls -l "$OUT"
echo "DIAG_BOOT_OK  (boot it with:  fastboot boot $OUT)"
