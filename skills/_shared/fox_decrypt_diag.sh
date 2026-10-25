#!/system/bin/sh
#
# Records the state of the /data decryption service chain into /tmp/recovery.log while a recovery starts.
#
#   recovery (vold code) -> keystore2 -> Keymaster HAL (+ gatekeeper) -> TEE daemon (qseecomd on Qualcomm) -> secure world
#
# If one link of that chain does not come up, decrypting /data blocks. This script only READS (properties, process
# list, kernel and logcat output) and appends what it finds to the recovery log, so that
#   adb pull /tmp/recovery.log        (blocks starting with "fox-diag:")
#   adb pull /tmp/fox-decrypt-diag.log
# tells which link is missing. It never touches /data, /metadata or any key.
#
#   fox_decrypt_diag.sh run     snapshots about 4, 15, 40 and 90 seconds after it was started (stops early once /data is decrypted)
#   fox_decrypt_diag.sh final   one snapshot right now (start it when the decrypt gave up)
#
# Service names differ per device (keymaster-4-1-qti, keymint, gatekeeper-1-0-qti, weaver ...): the init.svc.* properties of
# everything that matches SVC_RE are listed, so nothing has to be edited per device. Extend SVC_RE / PROC_RE for a new SoC.
#
# Test hooks (used by the skill's smoke test, harmless on a phone): FOX_DIAG_LOG, FOX_DIAG_OUT.

LOG=${FOX_DIAG_LOG:-/tmp/recovery.log}
OUT=${FOX_DIAG_OUT:-/tmp/fox-decrypt-diag.log}
TMP=$OUT.tmp
SVC_RE='servicemanager|logd|keystore|prepdecrypt|qseecomd|keymaster|keymint|gatekeeper|weaver|citadel|vold|health|trustonic|mobicore|tee'
PROC_RE='PID|qseecomd|keymaster|keymint|gatekeeper|weaver|keystore|servicemanager|logd|recovery|adbd|prepdecrypt|tee'

uptime_s() { cut -d' ' -f1 /proc/uptime; }

snapshot() {
    {
        echo "I:fox-diag: ===== $1 (uptime $(uptime_s)s) ====="
        echo "I:fox-diag: -- service state (init.svc.*)"
        getprop 2>/dev/null | grep -E "^\[init\.svc\.[^]]*($SVC_RE)" | sed 's/^/I:fox-diag: /'
        echo "I:fox-diag: -- properties"
        for p in hwservicemanager.ready crypto.ready vendor.sys.listeners.registered sys.listeners.registered \
                 keymaster_ver ro.crypto.state ro.crypto.type ro.crypto.fs_crypto_blkdev fox.decrypt.state \
                 ro.boot.bootdevice ro.boot.fastboot ro.boot.dynamic_partitions ro.boot.slot_suffix \
                 ro.build.version.release ro.build.version.security_patch ro.vendor.build.security_patch; do
            echo "I:fox-diag: $p=$(getprop $p)"
        done
        echo "I:fox-diag: -- processes (PID PPID STAT WCHAN NAME)"
        ps -A -o PID,PPID,STAT,WCHAN,NAME 2>/dev/null | grep -E "$PROC_RE" \
            || ps -A 2>&1 | grep -E "$PROC_RE"
        echo "I:fox-diag: -- device nodes the services need"
        ls -l /dev/qseecom /dev/ion /dev/binder /dev/hwbinder /dev/vndbinder /dev/tee* /dev/trusty* 2>&1 | grep -v "No such file"
        ls -l /dev/sg* 2>&1 | head -20
        ls -l /dev/block/bootdevice 2>&1
        ls /dev/block/bootdevice/by-name 2>&1 | tr '\n' ' '
        echo
        echo "I:fox-diag: -- trusted-app images (/vendor/firmware_mnt/image)"
        ls /vendor/firmware_mnt/image 2>&1 | grep -E "keymaste|cmnlib|gatekeep|weaver|No such|denied" | head -12
        echo "I:fox-diag: -- mounts"
        grep -E " /(vendor|firmware|vendor/firmware_mnt|metadata|data|persist|dev/binderfs) " /proc/mounts
        echo "I:fox-diag: -- logcat: the recovery's own decrypt steps (last 40 lines)"
        logcat -d -b all -v threadtime 2>&1 \
            | grep -E "MetadataCrypt|KeyStorage|KeyUtil|Keymaster\.cpp|FsCrypt|fscrypt|DmTarget|dm-default|Decrypt" \
            | tail -n 40
        echo "I:fox-diag: -- logcat: keystore2 / km_compat / KeyMint (last 40 lines)"
        logcat -d -b all -v threadtime 2>&1 \
            | grep -i -E "keystore2|km_compat|keymint|IKeystore|android\.security\.compat" \
            | tail -n 40
        echo "I:fox-diag: -- logcat: service manager, HAL registration (last 40 lines)"
        logcat -d -b all -v threadtime 2>&1 \
            | grep -i -E "hwservicemanager|ServiceManager|getTransport|VINTF|vintf|manifest" \
            | tail -n 40
        echo "I:fox-diag: -- logcat (decryption related, QSEECOM debug lines left out, last 120 lines)"
        logcat -d -b all -v threadtime 2>&1 \
            | grep -i -E "QSEECOM|qseecom|keymaster|keystore|vold|servicemanager|rpmb|ssd|libc +F|DEBUG|crash|abort|Fatal" \
            | grep -v -E " D (QSEECOMD|QSEECOMAPI|DrmLib[A-Za-z]*|DrmLibRpmb|LibSsd)" \
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
