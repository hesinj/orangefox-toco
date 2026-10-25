#!/system/bin/sh
#
# Black-box recorder for a recovery that hangs or panics at random.
#
# A boot that freezes is lost when the phone is restarted by hand. This script writes the state of the recovery to
# /cache/fox-bb/boot-N.log (the last 4 boots are kept) every few seconds and flushes it (sync), so that the next boot
# that comes up can fetch it:  adb pull /cache/fox-bb
#
# DESIGN RULE: it is PASSIVE. It reads only procfs, init properties and the kernel log, and it writes only to /cache (a
# small partition that is not /data and not /metadata). Everything it reads has to be harmless to read at any moment of the
# boot. A first version of this recorder (toco r7) also read CPU frequencies, every thermal zone, the battery and the kernel
# stacks of blocked tasks; the two boots that recorded those reads both froze within a second or two of the first
# snapshot. Whether the reads caused it was never proven (they could not be ruled out), so they were removed and every
# later boot was fine. A recorder must never be an extra suspect: do not add sensor, i2c, thermal or battery reads here.
#
# Once per boot, before the first snapshot: kernel version and command line, the physical memory map (/proc/iomem), the
# range the bootloader loaded the ramdisk into, and a copy of the kernel log of the PREVIOUS boot (pstore) if there is one,
# so the evidence survives a boot of another OS in between.
#
# Per snapshot (every 2 s for the first 150 s, then every 10 s, for about 15 minutes): uptime, load, memory, the decryption
# services' state, processes in D/T/Z state, where the recovery's threads sleep, and the kernel log lines that appeared since
# the previous snapshot. The log lines matter most: a boot that freezes leaves its last kernel messages in /cache even when
# pstore (RAM) does not survive the power cycle.
#
# Test hooks (harmless on a phone): FOX_BB_DIR, FOX_BB_MOUNTS. NOISE is a regex of kernel-log chatter to drop (battery gauge, charger, touch
# driver ...): extend it for the device, otherwise the 200-line cap per snapshot fills with noise.

DIR=${FOX_BB_DIR:-/cache/fox-bb}
MOUNTS=${FOX_BB_MOUNTS:-/proc/mounts}
NOISE=${FOX_BB_NOISE:-'QG-K|charger|QCOM-STEPCHG|ibat_ua|THERMAL_STATUS|fv calibrate|batt_verified|smb[0-9]_|usbpd'}
i=0
while ! grep -q " /cache " "$MOUNTS"; do
    i=$((i + 1))
    [ "$i" -gt 90 ] && exit 0
    sleep 1
done
mkdir -p "$DIR" || exit 0

n=$(cat "$DIR/counter" 2>/dev/null)
n=$((${n:-0} + 1))
echo "$n" > "$DIR/counter"
rm -f "$DIR/boot-$((n - 4)).log"
LOG="$DIR/boot-$n.log"
K=/tmp/fox-bb-k.txt
lastk=0

up() { cut -d' ' -f1 /proc/uptime; }

snap() {
    echo "===== uptime $(up)  load $(cut -d' ' -f1-3 /proc/loadavg)"
    grep -E "^(MemFree|MemAvailable|Slab|SUnreclaim):" /proc/meminfo | tr -s ' ' | tr '\n' ' '
    echo
    # where the decryption chain is (init properties only), then processes in uninterruptible sleep or stopped
    printf 'svc:'
    for k in $(getprop 2>/dev/null | grep -E '^\[init\.svc\.[^]]*(qseecomd|keymaster|keymint|gatekeeper|keystore|prepdecrypt)' | sed 's/^\[\([^]]*\)\].*/\1/'); do
        printf ' %s=%s' "${k#init.svc.}" "$(getprop $k)"
    done
    printf ' crypto.ready=%s listeners=%s' "$(getprop crypto.ready)" "$(getprop vendor.sys.listeners.registered)"
    echo
    ps -A -o PID,PPID,STAT,WCHAN,NAME 2>/dev/null | grep -E '^ *[0-9]+ +[0-9]+ +[DTZ]' > /tmp/fox-bb-d.txt
    if [ -s /tmp/fox-bb-d.txt ]; then
        echo "blocked processes (PID PPID STAT WCHAN NAME):"
        cat /tmp/fox-bb-d.txt
    fi
    # the recovery's threads: where do they sleep (wchan is a plain procfs read)
    rp=$(pidof recovery)
    if [ -n "$rp" ]; then
        printf 'recovery threads (tid:wchan):'
        for t in /proc/$rp/task/*; do printf ' %s:%s' "$(basename "$t")" "$(cat "$t/wchan" 2>/dev/null)"; done
        echo
    fi
    # kernel log lines since the previous snapshot
    dmesg > "$K" 2>/dev/null
    total=$(wc -l < "$K")
    [ "$total" -lt "$lastk" ] && lastk=0
    if [ "$total" -gt "$lastk" ]; then
        echo "kernel log (new lines):"
        if [ "$lastk" -eq 0 ]; then first=$((total > 120 ? total - 119 : 1)); else first=$((lastk + 1)); fi
        tail -n +$first "$K" | grep -v -E "$NOISE" | head -n 200
        lastk=$total
    fi
}

header() {
    echo "===== boot $n header (uptime $(up))"
    echo "kernel: $(cat /proc/version 2>/dev/null)"
    echo "cmdline: $(cat /proc/cmdline 2>/dev/null)"
    echo "--- /proc/iomem (RAM, kernel image, reserved ranges)"
    grep -E "System RAM|Kernel|reserved|ramoops|pstore" /proc/iomem 2>/dev/null | head -n 100
    echo "--- device tree /chosen: where the bootloader put the ramdisk"
    for f in linux,initrd-start linux,initrd-end; do
        p=/proc/device-tree/chosen/$f
        [ -e "$p" ] && printf '%s: 0x%s\n' "$f" "$(od -An -tx1 "$p" | tr -d ' \n')"
    done
    echo "--- pstore at start"
    ls -l /sys/fs/pstore 2>/dev/null
    if [ -s /sys/fs/pstore/console-ramoops-0 ]; then
        cp /sys/fs/pstore/console-ramoops-0 "$DIR/pstore-before-boot-$n.txt" 2>/dev/null
        rm -f "$DIR/pstore-before-boot-$((n - 4)).txt"
        echo "kernel log of the previous boot copied to $DIR/pstore-before-boot-$n.txt"
        grep -a -m3 -E "Oops|Kernel panic|Unable to handle|BUG:|KASAN|Poison|Redzone" /sys/fs/pstore/console-ramoops-0 | cut -c1-200
    fi
    echo "--- meminfo"
    head -n 8 /proc/meminfo
}
header >> "$LOG" 2>&1
sync

end=$(( $(cut -d. -f1 /proc/uptime) + 900 ))   # about 15 minutes
while [ "$(cut -d. -f1 /proc/uptime)" -lt "$end" ]; do
    snap >> "$LOG" 2>&1
    sync
    if [ "$(cut -d. -f1 /proc/uptime)" -lt 150 ]; then sleep 2; else sleep 10; fi
done
exit 0
