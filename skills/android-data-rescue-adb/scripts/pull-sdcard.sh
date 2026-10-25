#!/bin/sh
# pull-sdcard.sh DEST [PHONE_DIR]      (macOS / Linux; Windows has pull-sdcard.bat)
#
# Copies the phone's internal storage (default /sdcard) to DEST. Read-only on the phone: nothing is written there.
#   1. the top-level FILES in one tar stream (names with spaces or non-Latin letters survive),
#   2. every top-level FOLDER except Android with its own "adb pull", so that one folder that fails stops only itself;
#      a folder that fails is retried one level down,
#   3. Android/media (WhatsApp media and the like). Android/data and Android/obb (private data of apps) are left out on purpose.
# Needs the recovery up with /data decrypted ("recovery" in: adb devices). Environment: ADB (default adb), SDCARD (default /sdcard).
# Writes DEST/pull-report.txt, DEST/phone-files.txt (what the phone has) and compares the counts at the end.
# For a per-file explanation of what is missing: python3 compare_listing.py DEST/phone-files.txt DEST --root /sdcard
ADB="${ADB:-adb}"
SRC="${2:-${SDCARD:-/sdcard}}"; SRC="${SRC%/}"
DEST="${1:-}"
[ -n "$DEST" ] || { echo "usage: $0 destination-folder [phone-folder]"; exit 1; }
mkdir -p "$DEST" || { echo "cannot create $DEST"; exit 1; }
REPORT="$DEST/pull-report.txt"
$ADB get-state >/dev/null 2>&1 || { echo "no phone found by adb. Boot the recovery, wait for the password screen / menu, check: adb devices"; exit 1; }
echo "===== $(date)  copy of $SRC to $DEST" >> "$REPORT"

echo; echo "=== top-level files (one tar stream)"
if $ADB exec-out "cd '$SRC' && find . -maxdepth 1 -type f -print0 | xargs -0 -r tar -cf -" | tar -xf - -C "$DEST"; then
  echo "ok: top-level files" >> "$REPORT"
else
  echo "FAILED: top-level files, see the messages above" >> "$REPORT"; echo "FAILED: top-level files"
fi

echo; echo "=== top-level folders except Android"
$ADB exec-out "find '$SRC/' -maxdepth 1 -mindepth 1 -type d" | while IFS= read -r d; do
  d="$(printf '%s' "$d" | tr -d '\r')"; d="${d%/}"
  [ -n "$d" ] || continue
  [ "$d" = "$SRC/Android" ] && continue
  echo; echo "=== $d"
  if $ADB pull "$d" "$DEST"; then echo "ok: $d" >> "$REPORT"
  else
    echo "FAILED as a whole, retrying its contents one by one: $d" >> "$REPORT"; echo "FAILED: $d - retrying its contents one by one ..."
    n="${d##*/}"; mkdir -p "$DEST/$n"
    $ADB exec-out "find '$d' -maxdepth 1 -mindepth 1" | while IFS= read -r c; do
      c="$(printf '%s' "$c" | tr -d '\r')"; [ -n "$c" ] || continue
      $ADB pull "$c" "$DEST/$n" >/dev/null 2>&1 || echo "  FAILED: $c" >> "$REPORT"
    done
  fi
done

echo; echo "=== Android/media"
mkdir -p "$DEST/Android"
if $ADB pull "$SRC/Android/media" "$DEST/Android"; then echo "ok: Android/media" >> "$REPORT"
else echo "FAILED or missing: Android/media" >> "$REPORT"; echo "Android/media: FAILED or not present on the phone."; fi

echo
$ADB exec-out "find '$SRC/' -type f ! -path '$SRC/Android/data/*' ! -path '$SRC/Android/obb/*'" | tr -d '\r' > "$DEST/phone-files.txt"
DEVN=$(wc -l < "$DEST/phone-files.txt" | tr -d ' ')
LOCN=$(find "$DEST" -type f | wc -l | tr -d ' ')
echo "===== done. Skipped on purpose: Android/data, Android/obb."
echo "Files on the phone (without those two): $DEVN"
echo "Files in $DEST: $LOCN  (this includes pull-report.txt and phone-files.txt, so about two more than the phone is normal)"
echo "A smaller number here than on the phone means files that failed: see $REPORT and compare_listing.py"
