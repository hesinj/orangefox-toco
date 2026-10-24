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
#     adb shell sh /tmp/toco-probe.sh
#
# It starts what the full recovery starts for decrypting /data, in the same order and with the same
# environment: qseecomd, then the Keymaster 4.1 HAL, then the gatekeeper HAL. It does not touch /data,
# /metadata or any key, and it does not call the HALs. It only watches what the processes do.
#
# The relevant part of logcat and of the kernel log is streamed to the console while it runs, every step is
# announced BEFORE it runs, and the HAL steps print a line every second. If the phone freezes or restarts,
# the last lines on the PC show which step it was and how many seconds in. Afterwards (if adb still works):
#     adb pull /tmp/toco-probe.log
#
SYSLIB=/system/lib64
PROBE_LIBS=/tmp/probe-libs
export LD_LIBRARY_PATH=/vendor/lib64:/vendor/lib:/system/lib64:/system/lib:/sbin:$PROBE_LIBS
LOG=/tmp/toco-probe.log
LIVE=/tmp/probe-live.log
PAT='QSEECOM|qseecom|keymaster|gatekeeper|keystore|vold|servicemanager|linker|libc +[FE]|DEBUG|QISL|DrmLib|rpmb|SSD|BUG:|Oops|panic|Unable to handle|watchdog|hung task|blocked for more|Kernel panic'

t() { cut -d' ' -f1 /proc/uptime; }
say() { echo "[$(t)] $*"; }
alive() { if kill -0 "$1" 2>/dev/null; then echo yes; else echo NO; fi; }

threads() {
    # tid, name and the kernel function the thread is sleeping in
    [ -d "/proc/$1" ] || { echo "    (the process is gone)"; return; }
    for th in /proc/$1/task/*; do
        echo "    $(basename "$th") $(cat "$th/comm" 2>/dev/null) $(cat "$th/wchan" 2>/dev/null)"
    done 2>/dev/null
}

start_live() {
    logcat -c 2>/dev/null
    logcat -b all -v threadtime > "$LIVE" 2>&1 &
    LCPID=$!
    tail -f "$LIVE" 2>/dev/null | grep --line-buffered -i -E "$PAT" &
    GPID=$!
}

stop_live() {
    kill "$LCPID" "$GPID" 2>/dev/null
    for p in $(pidof tail); do kill "$p" 2>/dev/null; done
}

# watch NAME SECONDS PID: print a line every second while the process lives
watch_process() {
    i=0
    while [ "$i" -lt "$2" ]; do
        if [ "$(alive "$3")" = "NO" ]; then
            say "$1 exited after ${i}s"
            return
        fi
        sleep 1
        i=$((i + 1))
        say "$1 alive after ${i}s"
    done
}

main() {
    say "probe start, kernel $(uname -r)"
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
    [ "$miss" = 1 ] && return
    echo

    start_live

    # ---- step 1 -------------------------------------------------------------------------------
    say "== step 1: starting qseecomd (it must register its listeners)"
    old="$(pidof qseecomd)"
    if [ -n "$old" ]; then
        say "qseecomd is already running as pid $old, leaving it alone"
        QPID="$old"
    else
        /system/bin/qseecomd > /tmp/probe-qseecomd.out 2>&1 &
        QPID=$!
        # it sets this property once all its listeners are up
        j=0
        while [ "$j" -lt 25 ]; do
            [ "$(alive "$QPID")" = "NO" ] && break
            [ "$(getprop vendor.sys.listeners.registered)" = "true" ] && break
            sleep 1
            j=$((j + 1))
        done
    fi
    say "qseecomd: alive=$(alive "$QPID")  vendor.sys.listeners.registered='$(getprop vendor.sys.listeners.registered)'"
    if [ "$(alive "$QPID")" = "NO" ]; then
        say "RESULT: qseecomd is NOT running. Steps 2 and 3 are skipped."
        stop_live
        return
    fi
    if [ "$(getprop vendor.sys.listeners.registered)" != "true" ]; then
        say "RESULT: qseecomd runs but never reported its listeners as registered. Steps 2 and 3 are skipped."
        stop_live
        return
    fi
    echo

    # ---- step 2 -------------------------------------------------------------------------------
    say "== step 2: starting the Keymaster 4.1 HAL (loads the trusted app, registers with hwservicemanager)"
    say "   (if the phone freezes here, the next lines never appear; the last one tells how far it got)"
    /system/bin/android.hardware.keymaster@4.1-service-qti > /tmp/probe-keymaster.out 2>&1 &
    KPID=$!
    watch_process "keymaster HAL" 15 "$KPID"
    say "keymaster HAL: alive=$(alive "$KPID")"
    say "keymaster HAL threads (a registered HAL idles in binder_thread_read):"
    threads "$KPID"
    cat /tmp/probe-keymaster.out 2>/dev/null | tail -5
    echo
    if [ "$(alive "$KPID")" = "NO" ]; then
        say "RESULT: the Keymaster HAL exited. qseecomd is fine; the failure is in the HAL (see the log lines above)."
        sleep 2
        stop_live
        return
    fi

    # ---- step 3 -------------------------------------------------------------------------------
    say "== step 3: starting the gatekeeper HAL"
    /system/bin/android.hardware.gatekeeper@1.0-service-qti > /tmp/probe-gatekeeper.out 2>&1 &
    GPID2=$!
    watch_process "gatekeeper HAL" 6 "$GPID2"
    say "gatekeeper HAL: alive=$(alive "$GPID2")"
    threads "$GPID2"
    echo
    say "RESULT: qseecomd=$(alive "$QPID") keymaster=$(alive "$KPID") gatekeeper=$(alive "$GPID2")"
    say "        If all three are 'yes' the services themselves are fine and the stall is above them (keystore2 / the"
    say "        recovery's own decrypt call). They stay running; reboot the recovery when you are done."
    sleep 2
    stop_live
}

main 2>&1 | tee "$LOG"
