#!/system/bin/sh
#
# collect_device_facts.sh - read-only inventory of a phone for a recovery port. Runs ON the phone, in the booted ROM or in
# any recovery. It only reads: no write, no mount, no reboot, no root needed (sections that need root say so when empty).
#
#   adb push collect_device_facts.sh /data/local/tmp/ && adb shell sh /data/local/tmp/collect_device_facts.sh > facts.txt
#   (or without pushing:  adb shell sh < collect_device_facts.sh > facts.txt;  in a recovery use /tmp instead of /data/local/tmp)
#
# Run it in the ROM whose /data you want to read (the ROM decides the encryption flags and the HAL set), and again in the
# device's stock recovery if there is one. Section titles start with "=====" so the output can be searched.
#
# Interpretation guide: orangefox-fbe-recovery-port/references/intake-checklist.md

p() { printf '%s=%s\n' "$1" "$(getprop "$1")"; }
sec() { echo; echo "===== $*"; }
sizeof() {   # bytes of a by-name partition, from sysfs (readable without root)
    t=$(readlink -f "/dev/block/bootdevice/by-name/$1" 2>/dev/null) || return
    [ -n "$t" ] || return
    b=${t##*/}
    s=$(cat "/sys/class/block/$b/size" 2>/dev/null) || return
    [ -n "$s" ] && echo "$1 $((s * 512)) bytes  ($t)"
}

sec "identity"
for k in ro.product.device ro.product.name ro.product.model ro.product.brand ro.product.manufacturer ro.product.board \
         ro.board.platform ro.hardware ro.boot.hardware ro.soc.manufacturer ro.soc.model ro.product.cpu.abi \
         ro.product.cpu.abilist ro.build.fingerprint ro.build.version.release ro.build.version.sdk \
         ro.build.version.security_patch ro.vendor.build.security_patch ro.product.first_api_level \
         ro.vendor.api_level ro.treble.enabled ro.build.type ro.build.ab_update ro.boot.slot_suffix \
         ro.virtual_ab.enabled ro.boot.dynamic_partitions ro.boot.bootdevice ro.boot.verifiedbootstate \
         ro.boot.flash.locked ro.boot.vbmeta.device_state ro.boot.veritymode; do
    p "$k"
done
grep -E "^(Hardware|CPU part|CPU implementer)" /proc/cpuinfo 2>/dev/null | sort | uniq -c
grep -E "^MemTotal" /proc/meminfo 2>/dev/null

sec "kernel"
uname -a 2>/dev/null
cat /proc/version 2>/dev/null
echo "cmdline: $(cat /proc/cmdline 2>/dev/null)"
if [ -r /proc/config.gz ]; then
    echo "-- /proc/config.gz: options that matter for a recovery"
    (zcat /proc/config.gz 2>/dev/null || gzip -dc /proc/config.gz 2>/dev/null) | grep -E \
      '^CONFIG_(FS_ENCRYPTION|FS_ENCRYPTION_INLINE_CRYPT|BLK_INLINE_ENCRYPTION|BLK_INLINE_ENCRYPTION_FALLBACK|DM_DEFAULT_KEY|DM_CRYPT|SCSI_UFS_CRYPTO|SCSI_UFS_QCOM|SCSI_UFS_CRYPTO_QTI|QTI_CRYPTO_[A-Z_]*|CRYPTO_DEV_QCOM_ICE|F2FS_FS|F2FS_FS_COMPRESSION|F2FS_FS_ENCRYPTION|EROFS_FS|EXT4_FS_ENCRYPTION|PSTORE|PSTORE_RAM|PSTORE_CONSOLE|RD_GZIP|RD_BZIP2|RD_LZMA|RD_XZ|RD_LZO|RD_LZ4|RD_ZSTD|USB_CONFIGFS|USB_CONFIGFS_F_FS|ANDROID_BINDER_IPC|ANDROID_BINDERFS|SLAB_FREELIST_HARDENED|KASAN)(=|_.*=)' 2>/dev/null
else
    echo "(no /proc/config.gz: look at the ROM's kernel with scripts/kernel_marker_check.sh in the recovery-fbe-decryption skill)"
fi

sec "partitions (by-name) and sizes"
ls -l /dev/block/bootdevice/by-name 2>/dev/null || ls -l /dev/block/by-name 2>/dev/null
echo "-- sizes (sysfs)"
for n in boot recovery vendor_boot dtbo vbmeta super userdata metadata cache persist modem misc ssd; do sizeof "$n"; done
echo "-- logical partitions"
ls -l /dev/block/mapper 2>/dev/null
echo "-- (group name and sizes of the super partition need root: lpdump, or dump_super_partitions on a host)"

sec "mounts (data, metadata, firmware)"
grep -E " /(data|metadata|cache|persist|vendor|vendor/firmware_mnt|firmware|mnt/vendor/[a-z]*) " /proc/mounts 2>/dev/null

sec "fstab files (userdata, metadata lines)"
for f in /vendor/etc/fstab.* /vendor/etc/*.fstab /odm/etc/fstab.* /system/etc/fstab.* /fstab.* /first_stage_ramdisk/fstab.* /system/vendor/etc/fstab.*; do
    [ -f "$f" ] || continue
    echo "-- $f"
    grep -E "^[^#].*(/data|/metadata|userdata|/firmware|/persist|/cache)[[:space:]]" "$f" 2>/dev/null
done

sec "HAL manifest entries (keymaster / keymint / gatekeeper / weaver)"
for f in /vendor/etc/vintf/manifest.xml /vendor/etc/vintf/manifest/*.xml /odm/etc/vintf/manifest.xml /odm/etc/vintf/manifest/*.xml /vendor/manifest.xml; do
    [ -f "$f" ] || continue
    echo "-- $f"
    grep -E -A12 "<name>android\.hardware\.(keymaster|security\.keymint|security\.rkp|security\.secureclock|security\.sharedsecret|gatekeeper|weaver)" "$f" 2>/dev/null \
      | grep -E "<name>|<version>|<fqname>|<instance>|format=|<hal "
done
echo "-- target-level / sepolicy"
grep -h -E "target-level|<sepolicy>|<version>[0-9]+\.[0-9]+</version>" /vendor/etc/vintf/manifest.xml 2>/dev/null | head -5

sec "decryption-related binaries"
ls -l /vendor/bin 2>/dev/null | grep -i -E "qseecom|tee|trusty|gatekeeper|keymaster|keymint|weaver|hwservicemanager|vold"
ls -l /vendor/bin/hw 2>/dev/null | grep -i -E "keymaster|keymint|gatekeeper|weaver|secure|rkp"
ls -l /system/bin 2>/dev/null | grep -i -E "keystore|vold"
ls -l /vendor/lib64 2>/dev/null | grep -i -E "QSEEComAPI|keymaster|keymint|gatekeeper|qcbor|librpmb|libssd|libdrmfs"

sec "init service stanzas of those HALs (copy user/group/capabilities from here into the recovery rc)"
grep -h -A14 -E "^service [^ ]*(keymaster|keymint|gatekeeper|weaver|qseecomd)" \
    /vendor/etc/init/*.rc /vendor/etc/init/hw/*.rc /odm/etc/init/*.rc /system/etc/init/*.rc 2>/dev/null | head -160

sec "trusted-app firmware (Qualcomm: the modem/firmware partition mounted at /vendor/firmware_mnt or /firmware)"
for d in /vendor/firmware_mnt/image /firmware/image /vendor/firmware; do
    [ -d "$d" ] && { echo "-- $d"; ls "$d" 2>/dev/null | grep -i -E "keymaste|keym|gatekeep|cmnlib|weaver|widevine|qsee|km" | head -20; }
done
grep -E "firmware|modem" /proc/mounts 2>/dev/null

sec "pstore / ramoops (needed to read a kernel panic after a forced restart)"
ls -l /sys/fs/pstore 2>/dev/null
echo "ramoops on the command line: $(grep -o 'ramoops[^ ]*' /proc/cmdline 2>/dev/null | tr '\n' ' ')"
for f in /sys/module/ramoops/parameters/*; do [ -r "$f" ] && echo "$(basename "$f")=$(cat "$f" 2>/dev/null)"; done
ls /proc/device-tree/reserved-memory 2>/dev/null | grep -i ramoops

sec "usb gadget"
ls /sys/class/udc 2>/dev/null
p ro.boot.usbcontroller
p sys.usb.controller
p persist.vendor.usb.config
p ro.serialno

sec "display and input"
wm size 2>/dev/null
wm density 2>/dev/null
for d in /sys/class/backlight/*; do
    [ -d "$d" ] && echo "$d max=$(cat "$d/max_brightness" 2>/dev/null) now=$(cat "$d/brightness" 2>/dev/null)"
done
grep -E "^N: Name|^H: Handlers" /proc/bus/input/devices 2>/dev/null | paste - - 2>/dev/null || grep -E "^N: Name" /proc/bus/input/devices 2>/dev/null

sec "end"
