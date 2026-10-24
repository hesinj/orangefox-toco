#!/system/bin/sh
#
# toco: record the state of the decryption service chain in /tmp/recovery.log
#
#   qseecomd -> Keymaster HAL (+ gatekeeper) -> keystore2 -> vold code inside the recovery process
#
# If one link of that chain does not come up, decrypting /data blocks. This script only reads
# (properties, process list, kernel/logcat output) and appends what it finds to the recovery log,
# so that "adb pull /tmp/recovery.log" tells which link is missing.
#
#   fox_decrypt_diag.sh run     snapshots at about 4, 15, 40 and 90 seconds after it was started
#   fox_decrypt_diag.sh final   one snapshot right now (started when the decrypt gave up)
#

LOG=/tmp/recovery.log
OUT=/tmp/fox-decrypt-diag.log
TMP=/tmp/fox-decrypt-diag.tmp

uptime_s() { cut -d' ' -f1 /proc/uptime; }

snapshot() {
    {
        echo "I:fox-diag: ===== $1 (uptime $(uptime_s)s) ====="
        echo "I:fox-diag: -- service/property state"
        for p in init.svc.servicemanager init.svc.hwservicemanager init.svc.vndservicemanager \
                 init.svc.logd init.svc.keystore2 init.svc.prepdecrypt init.svc.qseecomd \
                 init.svc.keymaster-4-1-qti init.svc.gatekeeper-1-0-qti \
                 hwservicemanager.ready crypto.ready vendor.sys.listeners.registered \
                 sys.listeners.registered keymaster_ver ro.crypto.state ro.crypto.type \
                 ro.crypto.fs_crypto_blkdev fox.decrypt.state ro.boot.bootdevice \
                 ro.boot.fastboot ro.boot.dynamic_partitions ro.build.version.release \
                 ro.build.version.security_patch ro.vendor.build.security_patch; do
            echo "I:fox-diag: $p=$(getprop $p)"
        done
        echo "I:fox-diag: -- processes (PID PPID STAT WCHAN NAME)"
        ps -A -o PID,PPID,STAT,WCHAN,NAME 2>/dev/null \
            | grep -E "PID|qseecomd|keymaster|gatekeeper|keystore|servicemanager|logd|recovery|adbd|prepdecrypt" \
            || ps -A 2>&1 | grep -E "PID|qseecomd|keymaster|gatekeeper|keystore|servicemanager|logd|recovery|adbd|prepdecrypt"
        echo "I:fox-diag: -- device nodes the services need"
        ls -l /dev/qseecom /dev/ion /dev/binder /dev/hwbinder /dev/vndbinder 2>&1
        ls -l /dev/sg* 2>&1 | head -20
        ls -l /dev/block/bootdevice 2>&1
        ls /dev/block/bootdevice/by-name 2>&1 | tr '\n' ' '
        echo
        echo "I:fox-diag: -- trusted-app images (/vendor/firmware_mnt/image)"
        ls /vendor/firmware_mnt/image 2>&1 | grep -E "keymaster|cmnlib|gatekeeper|No such|denied" | head -12
        echo "I:fox-diag: -- mounts"
        grep -E " /(vendor|firmware|vendor/firmware_mnt|metadata|data|persist|dev/binderfs) " /proc/mounts
        echo "I:fox-diag: -- logcat (decryption related, last 120 lines)"
        logcat -d -b all -v threadtime 2>&1 \
            | grep -i -E "QSEECOM|qseecom|keymaster|keystore|vold|servicemanager|rpmb|ssd|libc +F|DEBUG|crash|abort|Fatal" \
            | tail -n 120
        echo "I:fox-diag: -- kernel log (decryption related, last 80 lines)"
        dmesg 2>&1 \
            | grep -i -E "init: |qseecom|binder|avc:|rpmb|ufs.*(err|fail)|Service '|exited|segfault|keymaster|keystore" \
            | tail -n 80
        echo "I:fox-diag: ===== end of $1 ====="
    } > "$TMP" 2>&1
    cat "$TMP" >> "$OUT"
    cat "$TMP" >> "$LOG"
    rm -f "$TMP"
}

decrypted() { [ -n "$(getprop ro.crypto.fs_crypto_blkdev)" ]; }

case "$1" in
    final)
        snapshot "decrypt gave up"
        ;;
    *)
        sleep 4;  snapshot "T+4s"
        decrypted && exit 0
        sleep 11; snapshot "T+15s"
        decrypted && exit 0
        sleep 25; snapshot "T+40s"
        decrypted && exit 0
        sleep 50; snapshot "T+90s"
        ;;
esac
exit 0
