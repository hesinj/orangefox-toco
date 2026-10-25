#!/system/bin/sh
#
# android-boot-diagnose.sh - READ-ONLY evidence about why Android (the installed ROM) does not boot, collected from the
# recovery after /data has been decrypted.
#
# It never writes to /data, /metadata, /cache, /misc or any other partition. Everything it produces goes to /tmp (RAM) and is
# packed into /tmp/android-diag.tgz. The only thing it "mounts" is the ROM's own system/vendor partitions, read-only, on
# directories under /tmp, to read the build version; they are unmounted again at the end.
#
#   Windows:   tools\android-diagnose.bat          (pushes this file, runs it, pulls the archive to the Desktop)
#   by hand:   adb push android-boot-diagnose.sh /tmp/ && adb shell sh /tmp/android-boot-diagnose.sh
#              adb pull /tmp/android-diag.tgz .
#
# Run it with OrangeFox up and /data unlocked (the password page typed). Without the password the "CE" storage
# (/data/user/0, app data) is not readable, but everything this script needs from /data/system, /data/misc, /data/adb and
# /data/apex is device-encrypted and readable as soon as the metadata layer is open.

R="${DIAG_ROOT:-}"            # test hook: prefix for / (empty on the phone)
OUT="${DIAG_OUT:-/tmp/android-diag}"
BY="$R/dev/block/bootdevice/by-name"
mkdir -p "$OUT/files" 2>/dev/null || { echo "cannot create $OUT"; exit 1; }

say()  { echo "$*"; }
sec()  { { echo; echo "===== $*"; } >> "$F"; }
run()  { { echo "\$ $*"; "$@" 2>&1; } >> "$F"; }
txt()  { # first bytes of a small file, printable ASCII only (toybox tr has no [:print:] class: use octal ranges)
    [ -f "$1" ] || return
    { echo "--- $1  ($(wc -c < "$1" 2>/dev/null) bytes)"; head -c "${2:-1500}" "$1" 2>/dev/null | tr -c '\011\012\040-\176' '.'; echo; } >> "$F"
}
strs() { tr -c '\040-\176' '\n' < "$1" 2>/dev/null | grep -E '.{4,}'; }   # strings(1) replacement
newest() { # newest N regular files of a directory, one per line
    [ -d "$1" ] || return
    ls -t "$1" 2>/dev/null | head -n "$2" | while IFS= read -r n; do [ -f "$1/$n" ] && echo "$1/$n"; done
}

say "== android-boot-diagnose: collecting into $OUT (read-only)"

# ---------------------------------------------------------------- 01 summary
F="$OUT/01-summary.txt"; : > "$F"
sec "time and kernel"
run date
run uname -a
for p in ro.boot.bootreason ro.boot.verifiedbootstate ro.boot.slot_suffix ro.build.version.release ro.build.fingerprint; do echo "$p=$(getprop $p)" >> "$F"; done
sec "command line"; txt "$R/proc/cmdline" 3000
sec "mounts of interest"; grep -E " /(data|metadata|cache|system|system_ext|vendor|product|odm|sdcard|storage[^ ]*) " "$R/proc/mounts" >> "$F" 2>/dev/null
sec "free space (a full /data is a classic reason for Android not booting)"
run df -h /data /cache /metadata
sec "inodes"; run df -i /data

# ---------------------------------------------------------------- 02 BCB (does the phone keep being sent to recovery?)
F="$OUT/02-misc-bcb.txt"; : > "$F"
sec "misc partition (bootloader control block: a leftover 'boot-recovery' command sends the phone to recovery at every start)"
if [ -e "$BY/misc" ]; then
    dd if="$BY/misc" bs=2048 count=1 of="$OUT/files/misc-bcb.bin" 2>/dev/null
    { echo "first 2048 bytes, printable strings only:"; tr -c '\040-\176' '\n' < "$OUT/files/misc-bcb.bin" | grep -E '.{3,}' ; } >> "$F" 2>&1
    echo "(empty output above = the BCB holds no command; the raw 2048 bytes are in files/misc-bcb.bin)" >> "$F"
else
    echo "no $BY/misc" >> "$F"
fi

# ---------------------------------------------------------------- 03 /cache/recovery
F="$OUT/03-cache-recovery.txt"; : > "$F"
sec "/cache"; run ls -la "$R/cache" "$R/cache/recovery"
for f in command last_install last_locale last_log last_kmsg log; do txt "$R/cache/recovery/$f" 6000; done

# raw copies: the recovery keeps the kernel console of the boot before each recovery start (last_kmsg*) and its own log (last_log*)
mkdir -p "$OUT/files/cache-recovery" 2>/dev/null
for f in "$R"/cache/recovery/*; do
    [ -f "$f" ] || continue
    sz=$(wc -c < "$f" 2>/dev/null); [ "${sz:-0}" -gt 3000000 ] && continue
    cp "$f" "$OUT/files/cache-recovery/" 2>/dev/null
done
echo "raw copies of /cache/recovery/* (files up to 3 MB) are in files/cache-recovery/" >> "$F"

# ---------------------------------------------------------------- 04 /metadata
F="$OUT/04-metadata.txt"; : > "$F"
sec "/metadata (small partition: boot statistics, OTA state, the metadata-encryption key directory)"
run ls -la "$R/metadata"
run ls -la "$R/metadata/bootstat" "$R/metadata/ota" "$R/metadata/apex" "$R/metadata/watchdog" "$R/metadata/vold" "$R/metadata/userspacereboot"
for d in bootstat ota apex watchdog userspacereboot; do
    for f in "$R/metadata/$d"/*; do [ -f "$f" ] && txt "$f" 800; done
done

# ---------------------------------------------------------------- 05 /data layout
F="$OUT/05-data-layout.txt"; : > "$F"
sec "/data"; run ls -la "$R/data"
sec "/data/system"; run ls -la "$R/data/system"
sec "/data/misc/bootstat"; run ls -la "$R/data/misc/bootstat"
for f in "$R/data/misc/bootstat"/*; do [ -f "$f" ] && txt "$f" 400; done
sec "APEX state (an unfinished staged session or a broken active APEX makes boots fail)"
run ls -la "$R/data/apex" "$R/data/apex/active" "$R/data/apex/sessions" "$R/data/apex/backup" "$R/data/apex/decompressed"
sec "persistent properties that mention boot reasons"
if [ -f "$R/data/property/persistent_properties" ]; then
    strs "$R/data/property/persistent_properties" | grep -i -E "boot\.reason|bootreason|crash|panic|watchdog|reason" | head -40 >> "$F"
else
    echo "no $R/data/property/persistent_properties" >> "$F"
fi

# raw copies of the last shutdown's records and the boot-reason files
mkdir -p "$OUT/files/shutdown" "$OUT/files/metadata" 2>/dev/null
for f in "$R"/data/system/shutdown-checkpoints/* "$R"/data/system/shutdown-metrics.txt "$R"/data/system/last-header.txt "$R"/data/system/uiderrors.txt; do
    [ -f "$f" ] && cp "$f" "$OUT/files/shutdown/" 2>/dev/null
done
for f in "$R"/metadata/bootstat/* "$R"/metadata/watchdog/* "$R"/metadata/ota/* "$R"/metadata/userspacereboot/*; do
    [ -f "$f" ] && cp "$f" "$OUT/files/metadata/" 2>/dev/null
done

# ---------------------------------------------------------------- 05b what changed after the last clean shutdown
F="$OUT/05b-changed-since-shutdown.txt"; : > "$F"
REF="$R/data/system/shutdown-metrics.txt"; [ -f "$REF" ] || REF="$R/data/system/last-header.txt"
sec "files under /data and /metadata that are NEWER than $REF (the last Android shutdown). Anything written by a later Android boot shows"
echo "up here; if only the recovery's own folders appear, the failing boots never got as far as writing to /data." >> "$F"
if [ -f "$REF" ]; then
    echo "reference file time: $(ls -l "$REF" 2>/dev/null)" >> "$F"
    find "$R/data" -maxdepth 3 \( -path "$R/data/media" -o -path "$R/data/data" -o -path "$R/data/user" -o -path "$R/data/user_de" -o -path "$R/data/app" -o -path "$R/data/misc_ce" -o -path "$R/data/system_ce" \) -prune -o -newer "$REF" -print 2>/dev/null | head -n 300 >> "$F"
    echo "--- /metadata" >> "$F"
    find "$R/metadata" -maxdepth 3 -newer "$REF" 2>/dev/null | head -n 100 >> "$F"
else
    echo "no reference file" >> "$F"
fi

# ---------------------------------------------------------------- 06 crash evidence
F="$OUT/06-crashes.txt"; : > "$F"
sec "dropbox (system_server crashes, watchdogs, app crashes; names carry the time in ms since 1970)"
run ls -la "$R/data/system/dropbox"
sec "tombstones and ANRs"; run ls -la "$R/data/tombstones" "$R/data/anr"
n=0
for f in $(newest "$R/data/system/dropbox" 40) $(newest "$R/data/tombstones" 6) $(newest "$R/data/anr" 6); do
    sz=$(wc -c < "$f" 2>/dev/null); [ "${sz:-0}" -gt 2000000 ] && continue
    cp "$f" "$OUT/files/$(basename "$f")" 2>/dev/null && n=$((n + 1))
done
echo "copied $n of the newest crash files into files/" >> "$F"
sec "logd persistent logs, if enabled"; run ls -la "$R/data/misc/logd"

# ---------------------------------------------------------------- 07 root / modules / patchers
F="$OUT/07-root-and-modules.txt"; : > "$F"
sec "/data/adb (Magisk, KernelSU, APatch, LSPosed, boot-time scripts: the most common reason for a bootloop after a module)"
run ls -la "$R/data/adb"
run ls -la "$R/data/adb/modules" "$R/data/adb/modules_update" "$R/data/adb/post-fs-data.d" "$R/data/adb/service.d"
for m in "$R/data/adb/modules"/*; do
    [ -d "$m" ] || continue
    { echo "--- module $(basename "$m"): flags: $(ls "$m" 2>/dev/null | grep -E '^(disable|remove|update|skip_mount)$' | tr '\n' ' ')"; head -n 8 "$m/module.prop" 2>/dev/null; } >> "$F"
done
sec "root manager / patcher packages (names only)"
find "$R/data/app" -maxdepth 2 -mindepth 2 -type d 2>/dev/null | sed 's#.*/##' | grep -i -E "magisk|kernelsu|apatch|lsposed|zygisk|luckypatcher|chelpus|exovxalo" >> "$F"

# ---------------------------------------------------------------- 08 packages
F="$OUT/08-packages.txt"; : > "$F"
sec "package database"
run ls -la "$R/data/system/packages.xml" "$R/data/system/packages.xml.reservecopy" "$R/data/system/packages.xml.bak" "$R/data/system/packages.list" "$R/data/system/users"
if [ -f "$R/data/system/packages.xml" ]; then
    magic=$(head -c 4 "$R/data/system/packages.xml" 2>/dev/null | tr -c '\040-\176' '.')
    echo "packages.xml starts with: $magic   (ABX... = Android binary XML, normal on Android 12+; '<?xm' = text XML)" >> "$F"
    case "$magic" in
        "<?xm"*) echo "tail (a healthy file ends with </packages>):" >> "$F"; tail -c 120 "$R/data/system/packages.xml" 2>/dev/null | tr -c '\040-\176' '.' >> "$F"; echo >> "$F"
                 echo "package entries: $(grep -c '<package ' "$R/data/system/packages.xml" 2>/dev/null)" >> "$F" ;;
    esac
    echo "packages.xml and its reservecopy are $(cmp -s "$R/data/system/packages.xml" "$R/data/system/packages.xml.reservecopy" && echo identical || echo different)" >> "$F"
fi
sec "/data/app (package directory names, first 150)"
find "$R/data/app" -maxdepth 2 -mindepth 2 -type d 2>/dev/null | sed 's#.*/##' | head -n 150 >> "$F"

# ---------------------------------------------------------------- 09 sizes
F="$OUT/09-sizes.txt"; : > "$F"
sec "sizes in KB of the directories that can fill /data (the user's media and app data are left out on purpose: they take minutes)"
for d in app dalvik-cache system misc local adb apex tombstones anr vendor vendor_ce vendor_de system_ce system_de misc_ce misc_de; do
    [ -d "$R/data/$d" ] && du -sk "$R/data/$d" 2>/dev/null >> "$F"
done

# ---------------------------------------------------------------- 10 file system health
F="$OUT/10-filesystem.txt"; : > "$F"
sec "kernel messages about the file systems and the storage"
dmesg 2>/dev/null | tr -d '\033' | grep -i -E "f2fs|fsck|ext4-fs|erofs|dm-verity|verity|ufs.*(error|fail|timeout)|mmc.*error|I/O error" | head -n 80 >> "$F"
sec "f2fs counters"
for d in "$R"/sys/fs/f2fs/*; do
    [ -d "$d" ] || continue
    echo "--- $d" >> "$F"
    for k in "$d"/*; do
        [ -f "$k" ] || continue
        v=$(head -c 120 "$k" 2>/dev/null | head -n 1); [ -n "$v" ] && echo "$(basename "$k")=$v" >> "$F"
    done
done

# ---------------------------------------------------------------- 11 boot partitions
F="$OUT/11-boot-partitions.txt"; : > "$F"
sec "vbmeta flags (byte 123 of the AVB header: 0 = verification on, 1 = hashtree off, 2 = verification off)"
for p in vbmeta vbmeta_system vbmeta_vendor; do
    [ -e "$BY/$p" ] && echo "$p flags byte: $(dd if="$BY/$p" bs=1 skip=123 count=1 2>/dev/null | od -An -tu1 | tr -d ' ')   magic: $(dd if="$BY/$p" bs=1 count=4 2>/dev/null | tr -c '\040-\176' '.')" >> "$F"
done
sec "boot and recovery image first 64 bytes (magic ANDROID!, kernel size, load addresses)"
for p in boot recovery; do
    [ -e "$BY/$p" ] && { echo "--- $p"; dd if="$BY/$p" bs=64 count=1 2>/dev/null | od -An -tx1 | head -n 4; } >> "$F"
done

sec "all partitions and their sizes (bytes, from sysfs)"
for f in "$BY"/*; do
    n=$(basename "$f"); t=$(readlink -f "$f" 2>/dev/null); b=${t##*/}
    s=$(cat "/sys/class/block/$b/size" 2>/dev/null)
    [ -n "$s" ] && echo "$n $((s * 512)) $t" >> "$F"
done
sec "headers of the boot-related partitions (first 64 KiB of each vbmeta, first 4 KiB of the others) are in files/hdr-*.bin"
for p in vbmeta vbmeta_system vbmeta_vendor; do [ -e "$BY/$p" ] && dd if="$BY/$p" of="$OUT/files/hdr-$p.bin" bs=65536 count=1 2>/dev/null; done
for p in boot recovery dtbo; do [ -e "$BY/$p" ] && dd if="$BY/$p" of="$OUT/files/hdr-$p.bin" bs=4096 count=1 2>/dev/null; done
sec "sha256 of whole partitions (compare with the images of the installed ROM release; takes a few seconds)"
HASH=""
for c in "sha256sum" "toybox sha256sum" "busybox sha256sum"; do $c /dev/null >/dev/null 2>&1 && { HASH="$c"; break; }; done
if [ -z "$HASH" ]; then
    echo "no sha256sum available in this recovery" >> "$F"
else
    for p in boot dtbo recovery vbmeta vbmeta_system vbmeta_vendor misc; do
        [ -e "$BY/$p" ] && echo "$($HASH "$BY/$p" 2>/dev/null | cut -d' ' -f1)  $p" >> "$F"
    done
fi

# ---------------------------------------------------------------- 12 ROM version (read-only mounts under /tmp)
F="$OUT/12-rom-version.txt"; : > "$F"
sec "installed ROM (read from the logical partitions, mounted read-only under /tmp)"
mounted=""
for p in system vendor product; do
    mkdir -p "/tmp/diag_ro_$p" 2>/dev/null
    if [ -e "$R/dev/block/mapper/$p" ]; then
        mount -t erofs -o ro "$R/dev/block/mapper/$p" "/tmp/diag_ro_$p" 2>/dev/null || mount -o ro "$R/dev/block/mapper/$p" "/tmp/diag_ro_$p" 2>/dev/null && mounted="$mounted $p"
    fi
done
for f in /tmp/diag_ro_system/system/build.prop /tmp/diag_ro_system/build.prop /tmp/diag_ro_vendor/build.prop /tmp/diag_ro_product/etc/build.prop; do
    [ -f "$f" ] && { echo "--- $f"; grep -E "^ro\.(build\.(fingerprint|version\.(release|security_patch|incremental|sdk)|date$|description)|pixelos|modversion|product\.(device|name)|vendor\.build\.(fingerprint|security_patch))" "$f" | head -n 24; } >> "$F"
done
echo "mounted read-only:${mounted:- nothing (partitions not mappable here)}" >> "$F"
for p in $mounted; do umount "/tmp/diag_ro_$p" 2>/dev/null; done

# ---------------------------------------------------------------- 13 previous kernel log
F="$OUT/13-pstore.txt"; : > "$F"
sec "pstore: the kernel console of the boot BEFORE this recovery (if the installed ROM froze or panicked right before, it is here)"
run ls -la "$R/sys/fs/pstore"
for f in "$R"/sys/fs/pstore/*; do
    [ -f "$f" ] || continue
    cp "$f" "$OUT/files/pstore-$(basename "$f")" 2>/dev/null
done
sec "this recovery's kernel log, last 150 lines"; dmesg 2>/dev/null | tr -d '\033' | tail -n 150 >> "$F"

# ---------------------------------------------------------------- pack
tar -czf /tmp/android-diag.tgz -C "$(dirname "$OUT")" "$(basename "$OUT")" 2>/dev/null \
  || ( cd "$(dirname "$OUT")" && tar -cf - "$(basename "$OUT")" | gzip > /tmp/android-diag.tgz )
ls -la /tmp/android-diag.tgz
say
say "== done. Nothing on the phone was changed."
say "   Get the archive with:   adb pull /tmp/android-diag.tgz"
say
say "== quick look (the full text is in the archive):"
grep -h -E "^(Filesystem|/dev/block|/dev/[a-z0-9]+ )" "$OUT/01-summary.txt" 2>/dev/null | head -n 6
echo "misc BCB:"; sed -n '/misc partition/,$p' "$OUT/02-misc-bcb.txt" | tail -n +2 | head -n 6
echo "modules:"; grep -E "^--- module" "$OUT/07-root-and-modules.txt" 2>/dev/null | head -n 12
echo "newest dropbox files:"; ls -t "$R/data/system/dropbox" 2>/dev/null | head -n 5
exit 0
