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
# v3 (DIAG_DEEP=1, the default) adds what the quick run cannot show: every file of the ROM partitions is read through the file system
# (an unreadable or corrupt file shows up), every APEX package is checked with unzip -t, every partition except userdata is read raw
# (I/O errors, timing), the logical partitions are hashed twice (a flaky medium gives two different hashes), the clock offset of the
# recovery, the UFS descriptors and the storage errors of the kernel log. Nothing is written anywhere but /tmp (RAM).
#
# Run it with OrangeFox up and /data unlocked (the password page typed). Without the password the "CE" storage
# (/data/user/0, app data) is not readable, but everything this script needs from /data/system, /data/misc, /data/adb and
# /data/apex is device-encrypted and readable as soon as the metadata layer is open.

R="${DIAG_ROOT:-}"            # test hook: prefix for / (empty on the phone)
OUT="${DIAG_OUT:-/tmp/android-diag}"
TGZ="${DIAG_TGZ:-/tmp/android-diag.tgz}"   # test hook, like DIAG_ROOT and DIAG_OUT
DEEP="${DIAG_DEEP:-1}"                    # 0 = quick (about 20 s); 1 = also read every file and every partition once (3-6 min, still read-only); 2 = also read all of /data (+5-10 min)
BY="$R/dev/block/bootdevice/by-name"
mkdir -p "$OUT/files" 2>/dev/null || { echo "cannot create $OUT"; exit 1; }

say()  { echo "$*"; }
sec()  { { echo; echo "===== $*"; } >> "$F"; }
run()  { { echo "\$ $*"; "$@" 2>&1; } >> "$F"; }
# Text helpers. tr -c with a range is NOT usable here: on the reference recovery (toybox 0.8.4) it turned every letter and digit into a dot.
# cat -v shows non-printing bytes as ^X / M-x and leaves text alone; strings comes from toybox, grep -a -o is the fallback.
txt()  { # first bytes of a small file, shown safely
    [ -f "$1" ] || return
    { echo "--- $1  ($(wc -c < "$1" 2>/dev/null) bytes)"; head -c "${2:-1500}" "$1" 2>/dev/null | cat -v; echo; } >> "$F"
}
strs() { # readable text runs of at least $2 (default 4) characters
    strings -n "${2:-4}" "$1" 2>/dev/null || grep -a -o -E "[ -~]{${2:-4},}" "$1" 2>/dev/null
}
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
    { echo "first 2048 bytes, printable strings only:"; strs "$OUT/files/misc-bcb.bin" 3; } >> "$F" 2>&1
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
    magic=$(head -c 4 "$R/data/system/packages.xml" 2>/dev/null | cat -v)
    echo "packages.xml starts with: $magic   (ABX... = Android binary XML, normal on Android 12+; '<?xm' = text XML)" >> "$F"
    case "$magic" in
        "<?xm"*) echo "tail (a healthy file ends with </packages>):" >> "$F"; tail -c 120 "$R/data/system/packages.xml" 2>/dev/null | cat -v >> "$F"; echo >> "$F"
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
    [ -e "$BY/$p" ] && echo "$p flags byte: $(dd if="$BY/$p" bs=1 skip=123 count=1 2>/dev/null | od -An -tu1 | tr -d ' ')   magic: $(dd if="$BY/$p" bs=1 count=4 2>/dev/null | cat -v)" >> "$F"
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
for p in system system_ext vendor product odm; do
    mkdir -p "/tmp/diag_ro_$p" 2>/dev/null
    if [ -e "$R/dev/block/mapper/$p" ]; then
        mount -t erofs -o ro "$R/dev/block/mapper/$p" "/tmp/diag_ro_$p" 2>/dev/null || mount -o ro "$R/dev/block/mapper/$p" "/tmp/diag_ro_$p" 2>/dev/null && mounted="$mounted $p"
    fi
done
for f in /tmp/diag_ro_system/system/build.prop /tmp/diag_ro_system/build.prop /tmp/diag_ro_vendor/build.prop /tmp/diag_ro_product/etc/build.prop; do
    [ -f "$f" ] && { echo "--- $f"; grep -E "^ro\.(build\.(fingerprint|version\.(release|security_patch|incremental|sdk)|date$|description)|pixelos|modversion|product\.(device|name)|vendor\.build\.(fingerprint|security_patch))" "$f" | head -n 24; } >> "$F"
done
echo "mounted read-only:${mounted:- nothing (partitions not mappable here)}" >> "$F"

# ---------------------------------------------------------------- 14 every file readable, APEX integrity (v3)
if [ "$DEEP" -ge 1 ]; then
    F="$OUT/14-files-and-apex.txt"; : > "$F"
    if [ -z "$mounted" ]; then
        echo "no ROM partition could be mounted here: nothing to read" >> "$F"
    else
        say "== reading every file of the ROM partitions through the file system (about a minute) ..."
        sec "every regular file read once through the file system (a corrupt or unreadable file prints an error)"
        for p in $mounted; do
            s0=$(date +%s)
            n=$(find "/tmp/diag_ro_$p" -type f 2>/dev/null | wc -l)
            find "/tmp/diag_ro_$p" -type f -print0 2>/dev/null | xargs -0 cat 2>"$OUT/files/readerr-$p.txt" >/dev/null
            e=$(date +%s)
            echo "$p: $n files, $((e - s0)) s, read errors: $(wc -l < "$OUT/files/readerr-$p.txt" | tr -d ' ')" >> "$F"
            head -n 10 "$OUT/files/readerr-$p.txt" >> "$F"
        done
        sec "APEX packages (the boot-time apexd fails when any built-in package cannot be opened): unzip -t checks every CRC"
        echo x > /tmp/diag_zt.txt; rm -f /tmp/diag_zt.zip
        if zip -q /tmp/diag_zt.zip /tmp/diag_zt.txt >/dev/null 2>&1 && unzip -tq /tmp/diag_zt.zip >/dev/null 2>&1; then
            apex_ok=0; apex_bad=0
            for p in $mounted; do
                for a in "/tmp/diag_ro_$p/apex" "/tmp/diag_ro_$p/system/apex"; do
                    [ -d "$a" ] || continue
                    for f in "$a"/*.apex "$a"/*.capex; do
                        [ -f "$f" ] || continue
                        echo "$(wc -c < "$f" | tr -d ' ') $f" >> "$OUT/files/apex-list.txt"
                        if timeout 300 unzip -tq "$f" >/dev/null 2>&1; then apex_ok=$((apex_ok + 1)); else apex_bad=$((apex_bad + 1)); echo "BAD APEX: $f" >> "$F"; fi
                    done
                done
            done
            echo "APEX packages: $apex_ok intact, $apex_bad BAD (list with sizes: files/apex-list.txt)" >> "$F"
        else
            echo "unzip -t is not usable in this recovery: APEX integrity not checked" >> "$F"
        fi
        rm -f /tmp/diag_zt.txt /tmp/diag_zt.zip
        sec "storage errors in the kernel log after the reads"
        dmesg 2>/dev/null | grep -i -E "I/O error|blk_update_request|medium error|ufshcd.*(err|fail|timeout)|scsi.*(error|failed)|erofs.*(error|fail|corrupt)|Buffer I/O|decompress" | tail -n 40 >> "$F"
    fi
fi
for p in $mounted; do umount "/tmp/diag_ro_$p" 2>/dev/null; done

# ---------------------------------------------------------------- 13 previous kernel log
F="$OUT/13-pstore.txt"; : > "$F"
sec "pstore: the kernel console of the boot BEFORE this recovery (if the installed ROM froze or panicked right before, it is here)"
run ls -la "$R/sys/fs/pstore"
for f in "$R"/sys/fs/pstore/*; do
    [ -f "$f" ] || continue
    cp "$f" "$OUT/files/pstore-$(basename "$f")" 2>/dev/null
done
for bb in toco-bb fox-bb; do
    [ -d "$R/cache/$bb" ] || continue
    sec "/cache/$bb (the recorder of this recovery: pstore snapshots of earlier boots, newest 3, and the newest 2 boot logs, are in files/$bb)"
    run ls -la "$R/cache/$bb"
    mkdir -p "$OUT/files/$bb" 2>/dev/null
    for f in $(ls -t "$R/cache/$bb"/pstore-before-boot-*.txt 2>/dev/null | head -n 3) $(ls -t "$R/cache/$bb"/boot-*.log 2>/dev/null | head -n 2); do
        cp "$f" "$OUT/files/$bb/" 2>/dev/null
    done
done
sec "this recovery's kernel log, last 150 lines"; dmesg 2>/dev/null | tr -d '\033' | tail -n 150 >> "$F"

# ---------------------------------------------------------------- 15 raw read of the partitions (v3)
if [ "$DEEP" -ge 1 ]; then
    F="$OUT/15-storage-read.txt"; : > "$F"
    say "== reading the partitions raw (I/O errors, timing) ..."
    sec "raw read of every partition by name except userdata (dd to /dev/null: nothing is written); rc is dd's exit status"
    drop_caches() { sync; { echo 3 > "$R/proc/sys/vm/drop_caches"; } 2>/dev/null; }   # a second read must come from the medium, not from RAM
    rawread() {  # label device
        say "   $1"
        s0=$(date +%s)
        o=$(dd if="$2" of=/dev/null bs=1048576 conv=noerror 2>&1); rc=$?
        e=$(date +%s)
        echo "$1 size=$(blockdev --getsize64 "$2" 2>/dev/null) rc=$rc seconds=$((e - s0)) errors=$(echo "$o" | grep -c -i -E 'error|fail')" >> "$F"
        [ "$rc" != 0 ] && echo "$o" | head -n 5 >> "$F"
    }
    for f in "$BY"/*; do
        [ -e "$f" ] || continue
        n=$(basename "$f")
        case "$n" in userdata) [ "$DEEP" -ge 2 ] || { echo "$n skipped (DIAG_DEEP=2 reads it too)" >> "$F"; continue; } ;; esac
        rawread "$n" "$f"
    done
    sec "logical partitions: size and sha256 taken twice (two different hashes of an unchanged partition mean an unstable medium)"
    HASH2=""
    for c in "sha256sum" "toybox sha256sum" "busybox sha256sum"; do $c /dev/null >/dev/null 2>&1 && { HASH2="$c"; break; }; done
    for n in system system_ext product vendor odm vendor_dlkm odm_dlkm system_dlkm; do
        d="$R/dev/block/mapper/$n"; [ -e "$d" ] || continue
        if [ -z "$HASH2" ]; then echo "$n: no sha256sum available" >> "$F"; continue; fi
        say "   hashing $n twice"
        drop_caches; h1=$($HASH2 "$d" 2>/dev/null | cut -d' ' -f1)
        drop_caches; h2=$($HASH2 "$d" 2>/dev/null | cut -d' ' -f1)
        if [ "$h1" = "$h2" ] && [ -n "$h1" ]; then st=STABLE; else st="DIFFERENT-OR-UNREADABLE"; fi
        echo "$n size=$(blockdev --getsize64 "$d" 2>/dev/null) sha256=$h1 second=$h2 $st" >> "$F"
    done
    sec "logical partition devices"; run ls -la "$R/dev/block/mapper"
    sec "storage errors in the kernel log after the reads"
    dmesg 2>/dev/null | grep -i -E "I/O error|blk_update_request|medium error|ufshcd.*(err|fail|timeout)|scsi.*(error|failed)|Buffer I/O" | tail -n 40 >> "$F"
fi

# ---------------------------------------------------------------- 16 clock, UFS, boot properties (v3)
F="$OUT/16-clock-ufs-props.txt"; : > "$F"
sec "clock: the recovery's raw RTC and its real time (files written early in a boot carry the raw RTC; real = RTC + offset)"
run date
echo "date +%s: $(date +%s)   rtc0 since_epoch: $(cat "$R/sys/class/rtc/rtc0/since_epoch" 2>/dev/null)" >> "$F"
sec "modification times (epoch seconds) of the files that tell when the last boots happened"
for f in "$R/metadata/bootstat/persist.sys.boot.reason" "$R/data/system/shutdown-metrics.txt" "$R/data/property/persistent_properties" \
         "$R"/cache/recovery/*.UPDATED "$R/cache/recovery/last_install" "$R/cache/recovery/last_format_data"; do
    [ -e "$f" ] && echo "$(stat -c '%Y' "$f" 2>/dev/null) $f" >> "$F"
done
sec "UFS: descriptors that the kernel exposes (health, device); empty = this kernel exposes none"
find "$R/sys/devices" -maxdepth 7 -type f \( -path '*ufshc*/health_descriptor/*' -o -path '*ufshc*/device_descriptor/*' -o -path '*ufshc*/geometry_descriptor/*' \) 2>/dev/null | head -n 80 | while IFS= read -r f; do
    echo "${f#$R}: text=[$(head -c 120 "$f" 2>/dev/null | cat -v)] hex=[$(head -c 32 "$f" 2>/dev/null | od -An -tx1 | tr -s ' \n' ' ')]" >> "$F"
done
for b in sda sdb sdc sdd sde sdf; do
    [ -d "$R/sys/block/$b" ] && echo "$b: $(cat "$R/sys/block/$b/device/vendor" 2>/dev/null) $(cat "$R/sys/block/$b/device/model" 2>/dev/null) rev=$(cat "$R/sys/block/$b/device/rev" 2>/dev/null) state=$(cat "$R/sys/block/$b/device/state" 2>/dev/null) stat=$(cat "$R/sys/block/$b/stat" 2>/dev/null)" >> "$F"
done
[ -d "$R/sys/kernel/debug/ufshcd0" ] && { sec "ufshcd0 debugfs (only when debugfs is already mounted)"; for f in err_stats; do [ -f "$R/sys/kernel/debug/ufshcd0/$f" ] && { echo "--- $f"; cat "$R/sys/kernel/debug/ufshcd0/$f" 2>/dev/null; } >> "$F"; done; }
sec "bootloader-provided properties (serial numbers and identifiers left out)"
getprop 2>/dev/null | grep -E '^\[(ro\.boot\.|ro\.bootloader|ro\.baseband|ro\.hardware|ro\.product\.(device|name|model)|ro\.revision)' | grep -v -i -E 'serial|\.sn\]|imei|meid|cpuid|mac|psn|uid' >> "$F"

# ---------------------------------------------------------------- 17 crash and log partitions (v3.2)
if [ "$DEEP" -ge 1 ]; then
    F="$OUT/17-crash-partitions.txt"; : > "$F"
    sec "Xiaomi partitions that may hold crash or boot logs: size, first non-zero byte, readable text. Reads only; the first MiB of each goes to files/part-NAME-head.bin"
    for p in oops logdump minidump rawdump dbg devinfo; do
        d="$BY/$p"; [ -e "$d" ] || continue
        sz=$(blockdev --getsize64 "$d" 2>/dev/null)
        echo "--- $p  size=$sz" >> "$F"
        echo "compare with zeros: $(cmp "$d" /dev/zero 2>&1 | head -n 1)   (an EOF message and nothing else = the whole partition is zeros)" >> "$F"
        echo "first 64 bytes: $(dd if="$d" bs=64 count=1 2>/dev/null | od -An -tx1 | tr -s ' \n' ' ')" >> "$F"
        echo "readable text (first 40 runs of 8+ characters):" >> "$F"
        strs "$d" 8 | head -n 40 >> "$F"
        dd if="$d" of="$OUT/files/part-$p-head.bin" bs=1048576 count=1 2>/dev/null
    done
fi

# ---------------------------------------------------------------- 18 CPU and bus frequencies (v3.2)
F="$OUT/18-cpu.txt"; : > "$F"
sec "cpuinfo (first 60 lines)"; head -n 60 "$R/proc/cpuinfo" 2>/dev/null | cat -v >> "$F"
sec "per CPU: online, governor, current / min / max frequency (kHz), available frequencies"
for c in "$R"/sys/devices/system/cpu/cpu[0-9]*; do
    [ -d "$c" ] || continue
    echo "${c##*/} online=$(cat "$c/online" 2>/dev/null) gov=$(cat "$c/cpufreq/scaling_governor" 2>/dev/null) cur=$(cat "$c/cpufreq/scaling_cur_freq" 2>/dev/null) min=$(cat "$c/cpufreq/cpuinfo_min_freq" 2>/dev/null) max=$(cat "$c/cpufreq/cpuinfo_max_freq" 2>/dev/null) avail=$(cat "$c/cpufreq/scaling_available_frequencies" 2>/dev/null)" >> "$F"
done
sec "devfreq devices (memory bus, caches, storage): current / min / max frequency, governor"
for d in "$R"/sys/class/devfreq/*; do
    [ -d "$d" ] && echo "${d##*/} cur=$(cat "$d/cur_freq" 2>/dev/null) min=$(cat "$d/min_freq" 2>/dev/null) max=$(cat "$d/max_freq" 2>/dev/null) gov=$(cat "$d/governor" 2>/dev/null)" >> "$F"
done
sec "memory"; head -n 6 "$R/proc/meminfo" 2>/dev/null >> "$F"

# ---------------------------------------------------------------- 19 read-only file system checks (v3.2)
if [ "$DEEP" -ge 1 ]; then
    F="$OUT/19-fsck-readonly.txt"; : > "$F"
    sec "e2fsck -fn (read-only: -n answers no to every repair question) on ext4 partitions that are not mounted, and on a RAM copy of /metadata (which is mounted)"
    if command -v e2fsck >/dev/null 2>&1; then
        say "== read-only file system checks ..."
        for p in persist cust; do
            [ -e "$BY/$p" ] || continue
            echo "--- $p" >> "$F"
            timeout 240 e2fsck -fn "$BY/$p" >> "$F" 2>&1; echo "exit status $? (0 = clean, 4 = errors left, 8 = could not run)" >> "$F"
        done
        if [ -e "$BY/metadata" ]; then
            echo "--- metadata (checked on a copy in RAM)" >> "$F"
            sync; dd if="$BY/metadata" of=/tmp/metadata-copy.img bs=1048576 2>/dev/null
            timeout 120 e2fsck -fn /tmp/metadata-copy.img >> "$F" 2>&1; echo "exit status $?" >> "$F"
            rm -f /tmp/metadata-copy.img
        fi
    else
        echo "e2fsck is not available in this recovery" >> "$F"
    fi
fi

# ---------------------------------------------------------------- pack
tar -czf "$TGZ" -C "$(dirname "$OUT")" "$(basename "$OUT")" 2>/dev/null \
  || ( cd "$(dirname "$OUT")" && tar -cf - "$(basename "$OUT")" | gzip > "$TGZ" )
ls -la "$TGZ"
say
say "== done. Nothing on the phone was changed."
say "   Get the archive with:   adb pull $TGZ"
say
say "== quick look (the full text is in the archive):"
grep -h -E "^(Filesystem|/dev/block|/dev/[a-z0-9]+ )" "$OUT/01-summary.txt" 2>/dev/null | head -n 6
echo "misc BCB:"; sed -n '/misc partition/,$p' "$OUT/02-misc-bcb.txt" | tail -n +2 | head -n 6
echo "modules:"; grep -E "^--- module" "$OUT/07-root-and-modules.txt" 2>/dev/null | head -n 12
echo "newest dropbox files:"; ls -t "$R/data/system/dropbox" 2>/dev/null | head -n 5
echo "deep checks (read errors, bad APEX packages, unstable hashes):"; grep -h -E "read errors: [1-9]|BAD APEX|DIFFERENT|rc=[1-9]|errors=[1-9]|APEX packages:" "$OUT/14-files-and-apex.txt" "$OUT/15-storage-read.txt" 2>/dev/null | head -n 20
exit 0
