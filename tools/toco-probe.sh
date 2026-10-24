#!/system/bin/sh
#
# toco-probe.sh - bring up the decryption services by hand, one step at a time, and say what each step did.
#
# Use it in the "-nocrypt" recovery, which does not start these services by itself. That image lacks four HIDL
# libraries the Keymaster/gatekeeper HALs need; they are put into /tmp/probe-libs (nothing under /system is touched).
# toco-probe.bat does all of it; by hand:
#
#     adb shell mkdir -p /tmp/probe-libs
#     adb push probe-libs/. /tmp/probe-libs/
#     adb push toco-probe.sh /tmp/toco-probe.sh
#     adb shell sh /tmp/toco-probe.sh [qseecomd|all]
#
#   qseecomd   only step 1 (start qseecomd and watch it for a while)
#   all        steps 1 to 3 (default): qseecomd, then the Keymaster 4.1 HAL, then the gatekeeper HAL
#
# It starts what the full recovery starts for decrypting /data, in the same order and with the same
# environment. It does not touch /data, /metadata or any key, and it does not call the HALs. It only watches.
#
# If the phone freezes, two records survive:
#  * the console of the PC: every step is announced BEFORE it runs, there is a line per second while a service
#    starts, and new log lines are shown within half a second;
#  * the kernel log: every line printed here is also written to /dev/kmsg, so it is in the kernel's persistent
#    log (pstore). After a freeze, hold Power + Volume-Down until the phone restarts, keep holding Volume-Down so
#    it goes to fastboot instead of booting the system, boot the -nocrypt image again and read
#    /sys/fs/pstore/console-ramoops-0 (toco-logs.bat collects it).
#
SYSLIB=/system/lib64
PROBE_LIBS=/tmp/probe-libs
export LD_LIBRARY_PATH=/vendor/lib64:/vendor/lib:/system/lib64:/system/lib:/sbin:$PROBE_LIBS
LOG=/tmp/toco-probe.log
MODE="${1:-all}"
PAT='QSEECOM|qseecom|keymaster|gatekeeper|keystore|vold|servicemanager|linker|libc +[FE]|DEBUG|QISL|DrmLib|rpmb|SSD|ssd_'
KPAT='qseecom|rpmb|ufs|scm|tz |secure|watchdog|bark|bite|stall|hung|blocked|BUG:|Oops|panic|Unable to handle|binder: |dwc3|usb|thermal'

t() { cut -d' ' -f1 /proc/uptime; }
alive() { if kill -0 "$1" 2>/dev/null; then echo yes; else echo NO; fi; }

# say TEXT: console + kernel log (the kernel log survives a freeze, see above)
say() {
    echo "[$(t)] $*"
    echo "toco-probe: $*" > /dev/kmsg 2>/dev/null
}

threads() {
    # tid, name and the kernel function the thread is sleeping in
    [ -d "/proc/$1" ] || { echo "    (the process is gone)"; return; }
    for th in /proc/$1/task/*; do
        echo "    $(basename "$th") $(cat "$th/comm" 2>/dev/null) $(cat "$th/wchan" 2>/dev/null)"
    done 2>/dev/null
}

POLLED_LC=0
POLLED_K=0

# poll: show the userspace log lines and kernel lines that appeared since the last call, on the console and in
# the kernel log. Each call takes a fresh snapshot, so nothing waits in a buffer when the phone freezes.
poll() {
    logcat -d -b all -v threadtime 2>/dev/null > /tmp/probe-poll.txt
    n=$(( $(wc -l < /tmp/probe-poll.txt) ))
    [ "$n" -lt "$POLLED_LC" ] && POLLED_LC=0
    if [ "$n" -gt "$POLLED_LC" ]; then
        tail -n +$((POLLED_LC + 1)) /tmp/probe-poll.txt | grep -i -E "$PAT" > /tmp/probe-new.txt
        POLLED_LC=$n
        if [ -s /tmp/probe-new.txt ]; then
            cat /tmp/probe-new.txt
            while IFS= read -r line; do echo "toco-probe-log: $line" > /dev/kmsg 2>/dev/null; done < /tmp/probe-new.txt
        fi
    fi
    dmesg 2>/dev/null > /tmp/probe-k.txt
    n=$(( $(wc -l < /tmp/probe-k.txt) ))
    [ "$n" -lt "$POLLED_K" ] && POLLED_K=0
    if [ "$n" -gt "$POLLED_K" ]; then
        tail -n +$((POLLED_K + 1)) /tmp/probe-k.txt | grep -v "toco-probe" | grep -i -E "$KPAT" | sed 's/^/  kernel: /'
        POLLED_K=$n
    fi
}

# watch NAME SECONDS PID: while the process lives, poll twice a second and print a line every second
watch_process() {
    i=0
    while [ "$i" -lt "$2" ]; do
        if [ "$(alive "$3")" = "NO" ]; then
            poll
            say "$1 exited after ${i}s"
            return
        fi
        sleep 0.5
        poll
        sleep 0.5
        poll
        i=$((i + 1))
        say "$1 alive after ${i}s"
    done
}

main() {
    echo on > /proc/sys/kernel/printk_devkmsg 2>/dev/null   # do not rate-limit the markers written to /dev/kmsg
    say "probe start (mode $MODE), kernel $(uname -r)"
    if [ "$(getprop ro.orangefox.crypto_enabled)" = "1" ]; then
        say "NOTE: this recovery was built with decryption; its own init may already be starting these services."
        say "      The probe is meant for the -nocrypt image."
    fi
    say "== environment"
    say "ro.boot.bootdevice=$(getprop ro.boot.bootdevice)  hwservicemanager.ready=$(getprop hwservicemanager.ready)  init.svc.hwservicemanager=$(getprop init.svc.hwservicemanager)"
    ls -l /dev/qseecom /dev/ion 2>&1
    say "trusted-app images under /vendor/firmware_mnt/image:"
    ls /vendor/firmware_mnt/image 2>&1 | grep -E "keymaster|cmnlib|No such" | head -8
    miss=0
    for l in android.hardware.keymaster@3.0.so android.hardware.keymaster@4.0.so android.hardware.keymaster@4.1.so android.hardware.gatekeeper@1.0.so; do
        [ -f "$SYSLIB/$l" ] || [ -f "$PROBE_LIBS/$l" ] || { say "MISSING $l (push probe-libs/ to $PROBE_LIBS first; toco-probe.bat does that)"; miss=1; }
    done
    [ "$miss" = 1 ] && [ "$MODE" != "qseecomd" ] && return
    echo

    logcat -c 2>/dev/null
    POLLED_LC=0
    POLLED_K=$(( $(dmesg 2>/dev/null | wc -l) ))

    # ---- step 1 -------------------------------------------------------------------------------
    say "== step 1: starting qseecomd (it must register its listeners)"
    old="$(pidof qseecomd)"
    if [ -n "$old" ]; then
        say "qseecomd is already running as pid $old, leaving it alone"
        QPID="$old"
    else
        /system/bin/qseecomd > /tmp/probe-qseecomd.out 2>&1 &
        QPID=$!
        say "qseecomd started as pid $QPID"
        # it sets this property once all its listeners are up
        j=0
        while [ "$j" -lt 25 ]; do
            [ "$(alive "$QPID")" = "NO" ] && break
            [ "$(getprop vendor.sys.listeners.registered)" = "true" ] && break
            sleep 0.5
            poll
            sleep 0.5
            poll
            j=$((j + 1))
            say "waiting for qseecomd, ${j}s"
        done
    fi
    poll
    say "qseecomd: alive=$(alive "$QPID")  vendor.sys.listeners.registered='$(getprop vendor.sys.listeners.registered)'"
    if [ "$(alive "$QPID")" = "NO" ]; then
        say "RESULT: qseecomd is NOT running. Steps 2 and 3 are skipped."
        return
    fi
    if [ "$(getprop vendor.sys.listeners.registered)" != "true" ]; then
        say "RESULT: qseecomd runs but never reported its listeners as registered. Steps 2 and 3 are skipped."
        return
    fi
    if [ "$MODE" = "qseecomd" ]; then
        say "watching qseecomd idle for 20 more seconds"
        watch_process "qseecomd" 20 "$QPID"
        say "RESULT: qseecomd alone: alive=$(alive "$QPID")"
        return
    fi
    echo

    # ---- step 2 -------------------------------------------------------------------------------
    say "== step 2: starting the Keymaster 4.1 HAL (loads the trusted app, registers with hwservicemanager)"
    say "   (if the phone freezes here, the next lines never appear; the last one tells how far it got)"
    /system/bin/android.hardware.keymaster@4.1-service-qti > /tmp/probe-keymaster.out 2>&1 &
    KPID=$!
    say "keymaster HAL started as pid $KPID"
    watch_process "keymaster HAL" 15 "$KPID"
    say "keymaster HAL: alive=$(alive "$KPID")"
    say "keymaster HAL threads (a registered HAL idles in binder_thread_read):"
    threads "$KPID"
    tail -5 /tmp/probe-keymaster.out 2>/dev/null
    echo
    if [ "$(alive "$KPID")" = "NO" ]; then
        say "RESULT: the Keymaster HAL exited. qseecomd is fine; the failure is in the HAL (see the log lines above)."
        return
    fi

    # ---- step 3 -------------------------------------------------------------------------------
    say "== step 3: starting the gatekeeper HAL"
    /system/bin/android.hardware.gatekeeper@1.0-service-qti > /tmp/probe-gatekeeper.out 2>&1 &
    GPID2=$!
    say "gatekeeper HAL started as pid $GPID2"
    watch_process "gatekeeper HAL" 6 "$GPID2"
    say "gatekeeper HAL: alive=$(alive "$GPID2")"
    threads "$GPID2"
    echo
    say "RESULT: qseecomd=$(alive "$QPID") keymaster=$(alive "$KPID") gatekeeper=$(alive "$GPID2")"
    say "        If all three are 'yes' the services themselves are fine and the stall is above them (keystore2 / the"
    say "        recovery's own decrypt call). They stay running; reboot the recovery when you are done."
}

main 2>&1 | tee "$LOG"
