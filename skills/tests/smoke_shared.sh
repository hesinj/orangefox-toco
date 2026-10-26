#!/bin/bash
# Smoke tests for the five skills: no phone, no OrangeFox tree, no network. Run from anywhere:  bash skills/tests/smoke_shared.sh
# What they prove: every script parses, the shared copies are identical, every SKILL.md has valid front matter, and each script that
# can run on a PC does its job on small synthetic inputs (stub getprop/dmesg/logcat/adb, a made-up root, a made-up ramdisk).
# What they do not prove: behaviour on a real phone. Exit status 1 when any test fails.
set -u
SK="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/skills_smoke.XXXXXX")"
trap 'rm -r "$T" 2>/dev/null' EXIT
export PYTHONDONTWRITEBYTECODE=1
pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass+1)); }
ko() { echo "FAIL  $1"; fail=$((fail+1)); [ -n "${2:-}" ] && sed -n '1,12p' "$2" | sed 's/^/        /'; }
t() { local name="$1"; shift; if "$@" > "$T/last.out" 2>&1; then ok "$name"; else ko "$name" "$T/last.out"; fi; }
has() { grep -q -- "$2" "$1"; }

# ---------------------------------------------------------------- 1. syntax of everything
for f in $(find "$SK" -type f \( -name '*.sh' \) ! -path '*/unlzma_check/*'); do
  case "$(head -c 40 "$f" | head -1)" in *bash*) t "bash -n ${f#$SK/}" bash -n "$f" ;; *) t "sh -n ${f#$SK/}" sh -n "$f" ;; esac
done
pyfiles=$(find "$SK" -type f -name '*.py')
t "python syntax of all .py ($(echo "$pyfiles" | wc -l) files)" python3 -I -c 'import ast,sys
for f in sys.argv[1:]: ast.parse(open(f,encoding="utf-8").read(), f)' $pyfiles
t "shared files identical to their sources" "$SK/sync_shared.sh" --check

# ---------------------------------------------------------------- 2. front matter of the five skills
t "SKILL.md front matter (name = folder, description 1-1024 chars, no angle brackets)" python3 -I - "$SK" <<'PY'
import os, re, sys
root = sys.argv[1]
n = 0
for d in sorted(os.listdir(root)):
    p = os.path.join(root, d, "SKILL.md")
    if not os.path.isfile(p):
        continue
    s = open(p, encoding="utf-8").read()
    m = re.match(r"---\n(.*?)\n---\n", s, re.S)
    assert m, d + ": no front matter"
    fm = dict(re.findall(r"^([a-z-]+):\s*(.*)$", m.group(1), re.M))
    assert fm.get("name") == d, "%s: name %r differs from the folder" % (d, fm.get("name"))
    desc = fm.get("description", "")
    assert 1 <= len(desc) <= 1024, "%s: description is %d characters" % (d, len(desc))
    assert "<" not in desc and ">" not in desc, d + ": angle bracket in description"
    assert ": " not in desc and " #" not in desc, d + ": a colon+space or ' #' inside the plain description breaks YAML parsing"
    try:
        import yaml
        yaml.safe_load(m.group(1))
    except ImportError:
        pass
    assert set(fm) <= {"name", "description", "license", "allowed-tools", "metadata", "compatibility"}, d + ": unknown key"
    assert len(s.splitlines()) <= 500, d + ": SKILL.md longer than 500 lines"
    n += 1
assert n >= 5, "only %d skills found" % n
print(n, "skills ok")
PY
t "every file named in a SKILL.md exists" python3 -I - "$SK" <<'PY'
import os, re, sys
root = sys.argv[1]
bad = []
for d in sorted(os.listdir(root)):
    p = os.path.join(root, d, "SKILL.md")
    if not os.path.isfile(p):
        continue
    for ref in set(re.findall(r"`((?:references|scripts|assets)/[A-Za-z0-9_./-]+)`", open(p, encoding="utf-8").read())):
        if not os.path.exists(os.path.join(root, d, ref)):
            bad.append(d + ": " + ref)
assert not bad, "\n".join(bad)
PY

# ---------------------------------------------------------------- 3. stubs for a phone's tools
B="$T/bin"; mkdir -p "$B"
cat > "$B/getprop" <<'EOF'
#!/bin/sh
if [ -z "$1" ]; then printf '[init.svc.qseecomd]: [running]\n[init.svc.keymaster-4-1-qti]: [running]\n[init.svc.prepdecrypt]: [stopped]\n'; exit 0; fi
case "$1" in ro.crypto.fs_crypto_blkdev) ;; crypto.ready) echo 1 ;; init.svc.*) echo running ;; *) echo x ;; esac
EOF
cat > "$B/dmesg" <<'EOF'
#!/bin/sh
printf '[    1.0] init: starting service qseecomd\n[    2.0] binder: 1:1 transaction failed\n[    3.0] charger: QG-K noise\n'
EOF
printf '#!/bin/sh\nprintf "03-01 00:00:01.000   100   100 I Keymaster.cpp: Retrieving key from keymaster\\n"\n' > "$B/logcat"
cat > "$B/sleep" <<'EOF'
#!/bin/sh
# no real waiting; after SLEEP_LIMIT calls stop the calling script (a recorder loops for 15 minutes)
f="${SLEEP_COUNT:-/tmp/.sleep_count.$PPID}"; n=$(cat "$f" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$f"
[ -n "${SLEEP_LIMIT:-}" ] && [ "$n" -ge "$SLEEP_LIMIT" ] && kill "$PPID" 2>/dev/null
exit 0
EOF
chmod +x "$B"/*

# fox_decrypt_diag.sh: one snapshot
( PATH="$B:$PATH" FOX_DIAG_LOG="$T/recovery.log" FOX_DIAG_OUT="$T/diag.log" sh "$SK/recovery-fbe-decryption/scripts/fox_decrypt_diag.sh" final ) > "$T/last.out" 2>&1
if has "$T/recovery.log" "fox-diag: ===== decrypt gave up" && has "$T/recovery.log" "init.svc.qseecomd" && has "$T/recovery.log" "end of decrypt gave up"; then ok "fox_decrypt_diag.sh final writes a complete block with service states"; else ko "fox_decrypt_diag.sh final" "$T/recovery.log"; fi

# fox_blackbox.sh: header + at least two snapshots, noise filtered, boot counter
mkdir -p "$T/cache"; echo "/dev/x /cache ext4 rw 0 0" > "$T/mounts"
{ ( PATH="$B:$PATH" SLEEP_COUNT="$T/sleepcount" SLEEP_LIMIT=3 FOX_BB_DIR="$T/cache/fox-bb" FOX_BB_MOUNTS="$T/mounts" sh "$SK/recovery-boot-debugging/scripts/fox_blackbox.sh" ) > "$T/last.out" 2>&1; } 2>/dev/null
L="$T/cache/fox-bb/boot-1.log"
if [ -f "$L" ] && has "$L" "boot 1 header" && [ "$(grep -c '===== uptime' "$L")" -ge 2 ] && has "$L" "svc: qseecomd=running" && ! has "$L" "charger"; then ok "fox_blackbox.sh writes header + snapshots, filters noise, passive reads only"; else ko "fox_blackbox.sh" "$L"; fi
if ! grep -E "/sys/class/(thermal|power_supply)|cpufreq|/proc/[^ ]*/stack" "$SK/recovery-boot-debugging/scripts/fox_blackbox.sh" | grep -v '^#' | grep -q .; then ok "fox_blackbox.sh reads no thermal/battery/cpufreq/stack files (passive-only rule)"; else ko "fox_blackbox.sh passive rule"; fi

# ---------------------------------------------------------------- 4. diagnosis script on a made-up root
R="$T/root"; mkdir -p "$R/proc" "$R/data/system" "$R/metadata/bootstat" "$R/dev/block/bootdevice/by-name" "$R/cache/recovery" "$R/data/misc/bootstat" "$R/data/adb/modules/m1" "$R/sys/fs/pstore"
echo "Linux version 4.14.356 (test)" > "$R/proc/version"; echo "console=ttyMSM0" > "$R/proc/cmdline"; printf '/dev/x /data f2fs rw 0 0\n' > "$R/proc/mounts"
echo "bootloader,bootstrap-apexd-failed" > "$R/metadata/bootstat/persist.sys.boot.reason"; touch "$R/data/system/shutdown-metrics.txt"
head -c 2048 /dev/zero > "$R/dev/block/bootdevice/by-name/misc"; printf 'boot-recovery' | dd of="$R/dev/block/bootdevice/by-name/misc" conv=notrunc 2>/dev/null
echo "Kernel panic - not syncing: test" > "$R/sys/fs/pstore/console-ramoops-0"
( PATH="$B:$PATH" DIAG_ROOT="$R" DIAG_OUT="$T/diag" DIAG_TGZ="$T/diag.tgz" sh "$SK/android-data-rescue-adb/scripts/android-boot-diagnose.sh" ) > "$T/last.out" 2>&1
miss=""; for f in 01-summary 02-misc-bcb 03-cache-recovery 04-metadata 05-data-layout 05b-changed-since-shutdown 06-crashes 07-root-and-modules 08-packages 09-sizes 10-filesystem 11-boot-partitions 12-rom-version 13-pstore 15-storage-read 16-clock-ufs-props 17-crash-partitions 18-cpu 19-fsck-readonly; do [ -s "$T/diag/$f.txt" ] || miss="$miss $f"; done
if [ -z "$miss" ] && [ -s "$T/diag.tgz" ] && has "$T/diag/02-misc-bcb.txt" "boot-recovery" && has "$T/diag/04-metadata.txt" "bootstrap-apexd-failed" && [ -s "$T/diag/files/pstore-console-ramoops-0" ]; then ok "android-boot-diagnose.sh: 19 sections, BCB, boot reason, pstore copy, raw read, clock, archive"; else ko "android-boot-diagnose.sh (missing:$miss)" "$T/last.out"; fi

# ---------------------------------------------------------------- 5. ramdisk checker on a made-up ramdisk (host ELF files)
RD="$T/rd"; mkdir -p "$RD/system/bin" "$RD/system/lib64" "$RD/vendor/lib64"
cp /bin/true "$RD/system/bin/qseecomd"
need="$(python3 -I - /bin/true <<'PY'
import subprocess, sys
out = subprocess.run(["readelf", "-d", sys.argv[1]], capture_output=True, text=True).stdout
print(" ".join(l.split("[")[1].split("]")[0] for l in out.splitlines() if "(NEEDED)" in l))
PY
)"
if python3 -I "$SK/_shared/verify_ramdisk.py" "$RD" --elf system/bin/qseecomd --no-auto > "$T/last.out" 2>&1; then ko "verify_ramdisk.py must fail when a library is missing"; else
  if grep -q -i -E "ERROR|not found|missing" "$T/last.out"; then ok "verify_ramdisk.py reports a missing library (exit status non-zero)"; else ko "verify_ramdisk.py output" "$T/last.out"; fi
fi
libdir="$(dirname "$(ldd /bin/true 2>/dev/null | awk '/libc.so/{print $3; exit}')")"
if [ -n "$need" ] && [ -d "$libdir" ]; then
  for l in $need ld-linux-x86-64.so.2; do [ -e "$libdir/$l" ] && cp -L "$libdir/$l" "$RD/system/lib64/"; done
  if python3 -I "$SK/_shared/verify_ramdisk.py" "$RD" --elf system/bin/qseecomd --no-auto --search system/lib64 > "$T/last.out" 2>&1; then ok "verify_ramdisk.py accepts a complete closure"; else ko "verify_ramdisk.py complete closure" "$T/last.out"; fi
else echo "SKIP  verify_ramdisk.py closure test (no readelf/ldd on this host)"; fi

# ---------------------------------------------------------------- 6. log analyzer and the decode helper
mkdir -p "$T/logs"
cat > "$T/logs/recovery.log" <<'EOF'
I:Starting the UI...
prepdecrypt::Script complete. Device ready for decryption
fscrypt_mount_metadata_encrypted: /data
Retrieving key from keymaster
Successfully decrypted metadata encrypted data partition with new block device: '/dev/block/dm-3'
fscrypt_initialize_systemwide_keys
EOF
python3 -I "$SK/recovery-fbe-decryption/scripts/analyze_recovery_log.py" "$T/logs" > "$T/last.out" 2>&1
if has "$T/last.out" "/data decrypted and mounted .* PASS" && has "$T/last.out" "verdict"; then ok "analyze_recovery_log.py reads a success log"; else ko "analyze_recovery_log.py" "$T/last.out"; fi
t "slub_freelist_decode.py --selftest" python3 -I "$SK/recovery-boot-debugging/scripts/slub_freelist_decode.py" --selftest

# ---------------------------------------------------------------- 7. device-tree generator round trip
python3 -I "$SK/orangefox-fbe-recovery-port/scripts/new_device_from_template.py" --conf "$SK/orangefox-fbe-recovery-port/assets/device.conf.example" --out "$T/dev" --template "$SK/orangefox-fbe-recovery-port/assets/device-tree-template" > "$T/last.out" 2>&1
if [ -f "$T/dev/BoardConfig.mk" ] && [ -f "$T/dev/device.mk" ] && ! grep -rIl -E '@@[A-Z_]+@@|#@@(if|for|endif)' "$T/dev" | grep -q .; then ok "generator renders a device tree without unresolved template syntax"; else ko "generator round trip" "$T/last.out"; fi

# ---------------------------------------------------------------- 8. data rescue: pull script with a stub adb, listing comparison
P="$T/phone"; mkdir -p "$P/DCIM" "$P/Download" "$P/Android/data/com.x" "$P/Android/media/m"
printf a > "$P/DCIM/IMG_1.jpg"; printf b > "$P/Download/a b.txt"; printf c > "$P/Download/Photo.JPG"; printf d > "$P/Download/photo.jpg"; printf e > "$P/Download/what?.txt"
printf f > "$P/Android/data/com.x/secret"; printf g > "$P/Android/media/m/x.jpg"; printf h > "$P/top file.txt"
cat > "$B/adb" <<EOF
#!/bin/sh
P="$P"
case "\$1" in
  get-state) echo device ;;
  exec-out) shift; c=\$(printf '%s' "\$*" | sed "s#/sdcard#\$P#g")
            case "\$c" in *"tar -cf -"*) sh -c "\$c" ;; *) sh -c "\$c" | sed "s#\$P#/sdcard#g" ;; esac ;;
  pull) src=\$(printf '%s' "\$2" | sed "s#/sdcard#\$P#"); cp -r "\$src" "\$3" ;;
esac
EOF
chmod +x "$B/adb"
( PATH="$B:$PATH" sh "$SK/android-data-rescue-adb/scripts/pull-sdcard.sh" "$T/dest" ) > "$T/last.out" 2>&1
if [ -f "$T/dest/top file.txt" ] && [ -f "$T/dest/DCIM/IMG_1.jpg" ] && [ -f "$T/dest/Android/media/m/x.jpg" ] && [ ! -e "$T/dest/Android/data" ] && [ -s "$T/dest/phone-files.txt" ]; then ok "pull-sdcard.sh copies files, folders and Android/media, skips Android/data"; else ko "pull-sdcard.sh" "$T/last.out"; fi
python3 -I "$SK/android-data-rescue-adb/scripts/compare_listing.py" "$T/dest/phone-files.txt" "$T/dest" --root /sdcard --posix > "$T/last.out" 2>&1
if has "$T/last.out" "missing in the copy: 0"; then ok "compare_listing.py: complete copy -> 0 missing"; else ko "compare_listing.py complete copy" "$T/last.out"; fi
rm -f "$T/dest/Download/what?.txt" "$T/dest/Download/photo.jpg"
python3 -I "$SK/android-data-rescue-adb/scripts/compare_listing.py" "$T/dest/phone-files.txt" "$T/dest" --root /sdcard --windows > "$T/last.out" 2>&1
if has "$T/last.out" "missing in the copy: 2" && has "$T/last.out" "invalid character" && has "$T/last.out" "case collision"; then ok "compare_listing.py explains an invalid character and a case collision"; else ko "compare_listing.py reasons" "$T/last.out"; fi

# ---------------------------------------------------------------- 9. build skill: image verifier argument handling, kernel helper
t "verify_image.sh rejects a missing image with a usage message" bash -c "! bash '$SK/recovery-build-environment/scripts/verify_image.sh' 2>&1 | grep -q 'usage' && exit 1; exit 0"
t "inventory.py / drop_objs.py on a tiny manifest" bash -c "
  mkdir -p '$T/tree/.repo/projects/a.git' '$T/tree/.repo/project-objects/p-a.git' '$T/tree/a/.git'
  printf '<manifest><project name=\"p-a\" path=\"a\"/></manifest>' > '$T/m.xml'
  python3 -I '$SK/recovery-build-environment/scripts/inventory.py' '$T/tree' '$T/m.xml' | grep -q 'projects total: 1' &&
  python3 -I '$SK/recovery-build-environment/scripts/drop_objs.py' '$T/tree' '$T/m.xml' a | grep -q removed &&
  [ ! -d '$T/tree/.repo/projects/a.git' ]"

# ---------------------------------------------------------------- 10. memstress: logic self test on the host (needs gcc)
if command -v gcc >/dev/null 2>&1 && [ "$(uname -m)" = x86_64 ]; then
  gcc -O2 -ffreestanding -fno-builtin -fno-stack-protector -fno-pic -no-pie -static -nostdlib -Wno-unused-but-set-variable -o "$T/memstress" "$SK/recovery-boot-debugging/scripts/memstress/memstress.c" > "$T/last.out" 2>&1 \
    && "$T/memstress" --seconds 5 1 2 --inject > "$T/ms.out" 2>&1; rc=$?
  if [ "$rc" = 2 ] && has "$T/ms.out" "failing bit positions: 17x1"; then ok "memstress finds the injected bit 17 and exits 2"; else ko "memstress self test (exit $rc)" "$T/ms.out"; fi
  "$T/memstress" --seconds 4 1 2 > "$T/ms.out" 2>&1; rc=$?
  if [ "$rc" = 0 ] && has "$T/ms.out" "errors: 0"; then ok "memstress reports no error on healthy memory (exit 0)"; else ko "memstress clean run (exit $rc)" "$T/ms.out"; fi
else echo "SKIP  memstress self test (needs gcc on x86_64)"; fi

# ---------------------------------------------------------------- 11. minidump parser on a synthetic dump
python3 -I - "$T/md.bin" <<'PY'
import struct, sys
lines = ["[%9.6f] %s\n" % (t, m) for t, m in [(100.0, "boot"), (101.5, "usb error -71"), (103.0, "Kernel panic - not syncing: test"), (50.0, "older line before the wrap"), (51.0, "another old line")]]
# ring order in the file: newest part first (offset 0 of the ring), the oldest after it: the seam is where time jumps back
body = "".join(lines).encode()
off = 0x4f8
buf = bytearray(0x600 + len(body))
buf[0:8] = b"cigamgol"; buf[0x400:0x408] = b"Raw_Dmp!"
p = 0x464
buf[p:p + 7] = b"md_kmsg"
struct.pack_into("<I", buf, p - 0x24, 3); struct.pack_into("<I", buf, p - 0x20, off); struct.pack_into("<I", buf, p - 0x18, len(body)); struct.pack_into("<Q", buf, p - 0x10, 0xb000000c)
buf[off:off + len(body)] = body
open(sys.argv[1], "wb").write(bytes(buf))
PY
python3 -I "$SK/recovery-boot-debugging/scripts/minidump_extract.py" "$T/md.bin" > "$T/last.out" 2>&1
if has "$T/last.out" "md_kmsg" && has "$T/last.out" "ring wraps" && has "$T/last.out" "Kernel panic - not syncing: test"; then ok "minidump_extract.py finds the region, the ring seam and the panic line"; else ko "minidump_extract.py" "$T/last.out"; fi

echo
echo "smoke tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
