#!/system/bin/sh
#
# toco-probe.sh - bring up the decryption services by hand, one step at a time, and say what each step did.
#
# Use it in the "-nocrypt" recovery, which does not start these services by itself:
#
#     adb push toco-probe.sh /tmp/toco-probe.sh
#     adb shell sh /tmp/toco-probe.sh
#
# It starts what the full recovery starts for decrypting /data, in the same order and with the same
# environment: qseecomd, then the Keymaster 4.1 HAL, then the gatekeeper HAL. It does not touch /data,
# /metadata or any key, and it does not call the HALs. It only watches what the processes do.
#
# Every step is announced BEFORE it runs. If the phone freezes or restarts, the last line shown on the PC
# says which step did it. Afterwards (if adb still works): adb pull /tmp/toco-probe.log
#
export LD_LIBRARY_PATH=/vendor/lib64:/vendor/lib:/system/lib64:/system/lib:/sbin
LOG=/tmp/toco-probe.log

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

# start_and_watch NAME SECONDS COMMAND...  -> sets WPID
start_and_watch() {
    name="$1"; secs="$2"; shift 2
    "$@" > "/tmp/probe-$name.out" 2>&1 &
    WPID=$!
    i=0
    while [ "$i" -lt "$secs" ]; do
        [ "$(alive "$WPID")" = "NO" ] && break
        sleep 1
        i=$((i + 1))
    done
}

main() {
    say "probe start, kernel $(uname -r)"
    say "== environment"
    say "ro.boot.bootdevice=$(getprop ro.boot.bootdevice)  hwservicemanager.ready=$(getprop hwservicemanager.ready)  init.svc.hwservicemanager=$(getprop init.svc.hwservicemanager)"
    ls -l /dev/qseecom /dev/ion 2>&1
    say "scsi generic nodes (UFS RPMB is reached through one of them):"
    ls -l /dev/sg* 2>&1 | head -12
    say "partitions the services use:"
    ls -l /dev/block/bootdevice/by-name/ssd /dev/block/bootdevice/by-name/keymaster* /dev/block/bootdevice/by-name/cmnlib* 2>&1
    say "trusted-app images under /vendor/firmware_mnt/image:"
    ls /vendor/firmware_mnt/image 2>&1 | grep -E "keymaster|cmnlib|No such" | head -8
    echo

    # ---- step 1 -------------------------------------------------------------------------------
    say "== step 1: starting qseecomd (it must register its listeners)"
    old="$(pidof qseecomd)"
    if [ -n "$old" ]; then
        say "qseecomd is already running as pid $old, leaving it alone"
        QPID="$old"
    else
        logcat -c 2>/dev/null
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
    say "qseecomd threads (tid name wchan):"
    threads "$QPID"
    say "log lines of qseecomd and its listeners:"
    logcat -d -v threadtime 2>&1 | grep -i -E "QSEECOM|rpmb|ssd|listener|libdrmfs" | tail -40
    say "kernel messages:"
    dmesg 2>&1 | grep -i -E "qseecom|rpmb|ufs.*(err|fail)|avc:.*qseecom" | tail -20
    echo
    if [ "$(alive "$QPID")" = "NO" ]; then
        say "RESULT: qseecomd is NOT running. This is where the decryption chain breaks (see the log lines above,"
        say "        for example 'RPMB_INIT failed' or 'SSD_INIT failed'). Steps 2 and 3 are skipped."
        return
    fi
    if [ "$(getprop vendor.sys.listeners.registered)" != "true" ]; then
        say "RESULT: qseecomd runs but never reported its listeners as registered; the Keymaster HAL would not be started."
        say "        Steps 2 and 3 are skipped."
        return
    fi

    # ---- step 2 -------------------------------------------------------------------------------
    say "== step 2: starting the Keymaster 4.1 HAL (loads the trusted app, registers with hwservicemanager)"
    logcat -c 2>/dev/null
    start_and_watch keymaster 12 /system/bin/android.hardware.keymaster@4.1-service-qti
    KPID="$WPID"
    say "keymaster HAL: alive=$(alive "$KPID")"
    say "keymaster HAL threads (a registered HAL idles in binder_thread_read):"
    threads "$KPID"
    say "log lines:"
    logcat -d -v threadtime 2>&1 | grep -i -E "keymaster|QSEECOM|hwservicemanager|keymint|libc +F|DEBUG" | tail -40
    cat /tmp/probe-keymaster.out 2>/dev/null | tail -5
    say "kernel messages:"
    dmesg 2>&1 | grep -i -E "qseecom|keymaster|avc:.*keymaster" | tail -10
    echo
    if [ "$(alive "$KPID")" = "NO" ]; then
        say "RESULT: the Keymaster HAL exited. qseecomd is fine; the failure is in the HAL (see its log lines above)."
        return
    fi

    # ---- step 3 -------------------------------------------------------------------------------
    say "== step 3: starting the gatekeeper HAL"
    logcat -c 2>/dev/null
    start_and_watch gatekeeper 6 /system/bin/android.hardware.gatekeeper@1.0-service-qti
    GPID="$WPID"
    say "gatekeeper HAL: alive=$(alive "$GPID")"
    threads "$GPID"
    logcat -d -v threadtime 2>&1 | grep -i -E "gatekeeper|QSEECOM|libc +F|DEBUG" | tail -20
    echo
    say "RESULT: qseecomd=$(alive "$QPID") keymaster=$(alive "$KPID") gatekeeper=$(alive "$GPID")"
    say "        If all three are 'yes', the services themselves are fine and the stall is above them (keystore2 / the"
    say "        recovery's own decrypt call). They stay running; reboot the recovery when you are done."
}

main 2>&1 | tee "$LOG"
