#!/system/bin/sh
#
# toco black-box recorder
#
# A boot that hangs or panics is lost when the phone is restarted by hand. This script writes the state of the
# recovery to /cache/toco-bb/boot-N.log (the last 4 boots are kept) every few seconds and flushes it, so that
# the next boot that comes up can fetch it (toco-logs.bat does: adb pull /cache/toco-bb).
#
# It only reads sysfs/procfs and writes to /cache (a small ext4 partition used for update commands). It does not touch
# /data, /metadata or any other partition.
#
# Once per boot, before the first snapshot: kernel version and command line, the physical memory map (/proc/iomem), the
# range the bootloader loaded the ramdisk into, and a copy of the kernel log of the PREVIOUS boot if it panicked
# (pstore), so the record survives a boot of another OS in between.
#
# Per snapshot: uptime and load, memory (free, slab, unreclaimable slab), CPU frequencies, every thermal zone and the
# battery/charger values (to see whether failures follow heat), processes that are not sleeping normally together
# with their kernel stacks, and the kernel log lines that appeared since the previous snapshot (a KASAN or SLUB
# report, an oops, an error from a driver).
#

DIR=/cache/toco-bb
i=0
while ! grep -q " /cache " /proc/mounts; do
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
    printf 'cpu_khz:'
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do printf ' %s' "$(cat "$f" 2>/dev/null)"; done
    echo
    printf 'thermal(mC):'
    for z in /sys/class/thermal/thermal_zone*; do
        printf ' %s=%s' "$(cat "$z/type" 2>/dev/null)" "$(cat "$z/temp" 2>/dev/null)"
    done
    echo
    printf 'battery:'
    for a in capacity status temp current_now voltage_now; do printf ' %s=%s' "$a" "$(cat /sys/class/power_supply/battery/$a 2>/dev/null)"; done
    echo
    # processes in uninterruptible sleep or stopped, with their kernel stacks
    ps -A -o PID,PPID,STAT,WCHAN,NAME 2>/dev/null | grep -E '^ *[0-9]+ +[0-9]+ +[DTZ]' > /tmp/fox-bb-d.txt
    if [ -s /tmp/fox-bb-d.txt ]; then
        echo "blocked processes (PID PPID STAT WCHAN NAME):"
        cat /tmp/fox-bb-d.txt
        while read -r pid rest; do
            echo "-- stacks of $pid"
            grep -H . /proc/$pid/task/*/stack 2>/dev/null | head -n 60
        done < /tmp/fox-bb-d.txt
    fi
    # the recovery's threads: where do they sleep
    rp=$(pidof recovery)
    if [ -n "$rp" ]; then
        printf 'recovery threads (tid wchan):'
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
        tail -n +$first "$K" | grep -v -E "ds28e16|GTP9886|QG-K|pm6150_charger|QCOM-STEPCHG|ibat_ua|Get prop 63|smb5_|usbpd|THERMAL_STATUS|fv calibrate|batt_verified" | head -n 200
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
