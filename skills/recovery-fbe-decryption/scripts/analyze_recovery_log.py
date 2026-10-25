#!/usr/bin/env python3
"""Read the logs of a recovery boot and say how far the /data decryption got and, if it stopped, which link of the chain is missing.

usage: analyze_recovery_log.py PATH [PATH ...]
  PATH is a log bundle directory (the folder the collect-logs scripts make; it is searched for recovery.log, recovery-pulled.log,
  fox-decrypt-diag.log, logcat.txt, dmesg.txt, pstore.txt, getprop.txt) or single files. Everything found is read together.

Output: a stage table (PASS / FAIL / not seen), the state of the decryption services at the last "Decrypt: waiting" line, every
known failure signature that matched with what it means and what to change, kernel oops / panic lines, and a one-line verdict.
The signatures are the ones seen on a real port (Qualcomm SM6150, Keymaster 4.1 HAL, OrangeFox fox_12.1 with the startup-hardening
patch); see references/failure-signatures.md for the reasoning behind each. Pure text matching: it never proves that decryption
works on a phone, it reads what the recovery itself reported.
"""
import os
import re
import sys

NAMES = ["recovery.log", "recovery-pulled.log", "fox-decrypt-diag.log", "fox-decrypt-diag-pulled.log", "logcat.txt",
         "dmesg.txt", "pstore.txt", "getprop.txt"]

# (label, regex). Stages in the order they happen on a working boot.
STAGES = [
    ("recovery UI started", r"Starting the UI\.\.\."),
    ("keymaster version read from the vendor manifest", r"Keymaster_Ver::Using keymaster version '([^']+)'"),
    ("prepdecrypt ran (props, crypto.ready=1)", r"prepdecrypt::Script complete\. Device ready for decryption"),
    ("metadata decrypt started", r"fscrypt_mount_metadata_encrypted: /data"),
    ("metadata key blob found", r"Key exists, using: (\S+)"),
    ("key requested from Keymaster", r"Retrieving key from keymaster"),
    ("Keymaster answered (key upgrade line)", r"Upgrading key: (\S+)"),
    ("encrypted file system mounting", r"Mounting metadata-encrypted filesystem:(\S+)"),
    ("/data decrypted and mounted", r"Successfully decrypted metadata encrypted data partition with new block device: '([^']+)'"),
    ("system-wide fscrypt keys installed", r"fscrypt_initialize_systemwide_keys"),
    ("device keys of user 0 loaded", r"fscrypt_init_user0|Installed de key for user 0"),
    ("user storage prepared", r"fscrypt_prepare_user_storage|Verified that /data/\S+ has the encryption policy"),
    ("user password accepted", r"(?i)user \d+ decrypted successfully|successfully decrypted user"),
]

# (regex, meaning, what to do). First the chain's own failures, then environment problems.
SIGNATURES = [
    (r"Failed to get ServiceManager|serviceManager\.get\(\)",
     "keystore2 (km_compat) aborts because libhidl will not hand out the HIDL service manager",
     "the ramdisk has no framework VINTF manifest declaring android.hidl.manager@1.2: add system/etc/vintf/manifest.xml (template in the skill's assets)"),
    (r"Cannot find entry android\.hidl\.manager@1\.2::IServiceManager/default|Cannot read /system/etc/vintf/manifest\.xml",
     "hwservicemanager found no framework VINTF manifest", "same fix: system/etc/vintf/manifest.xml in the ramdisk"),
    (r"RPMB_INIT failed|SSD_INIT failed",
     "qseecomd could not initialise the RPMB device or the ssd partition (mandatory steps)",
     "check /dev/sg* ownership and the ueventd rules, the ssd partition link, and that the UFS RPMB LUN exists"),
    (r"init\.svc\.keystore2=(restarting|stopped)",
     "keystore2 is not running", "see the keystore2 abort lines; usually the VINTF manifest or a missing library"),
    (r"Decrypt: the metadata decrypt did not finish within (\d+) seconds",
     "the bounded decrypt gave up", "read the 'Decrypt: waiting' lines and the fox-diag blocks for the first service that is not running"),
    (r"library \"?(?!libsecureui|libspl|libops)([^\s\"]+\.so)\"? not found|CANNOT LINK EXECUTABLE",
     "a service could not start: a shared library is missing in the ramdisk", "run verify_ramdisk.py on the unpacked image and add the library"),
    (r"QSEECOMD: : Init dlopen\((libsecureui|libspl|libops)\.so",
     "qseecomd looks for three optional libraries (secure UI, SPL, OPS) and runs without them", "harmless; do not add libops.so, it drags in the display stack"),
    (r"Keymaster_Ver::Unable to find vendor manifest",
     "the Keymaster version was not read from the ROM's vendor partition (default used)", "usually harmless; set TW_FORCE_KEYMASTER_VER + OF_DEFAULT_KEYMASTER_VERSION if the wrong HAL starts"),
    (r"Failed to mount '/metadata'|Unable to mount '/metadata'",
     "/metadata did not mount: the metadata encryption key is stored there", "check the /metadata line in recovery.fstab and the partition name"),
    (r"Unable to mount '/data'(?![\s\S]*Successfully decrypted)",
     "/data did not mount (before any decrypt this is normal: it is encrypted)", "only a problem when no 'Successfully decrypted' line follows"),
    (r"F2FS-fs \([^)]*\): (Magic Mismatch|Can't find valid)",
     "the kernel probed the raw encrypted userdata partition as f2fs", "normal before the decrypt (dm-default-key device not yet created)"),
    (r"Metadata FBE decrypt support not present in this build",
     "the recovery was built with TW_INCLUDE_CRYPTO but without TW_INCLUDE_FBE_METADATA_DECRYPT", "set TW_INCLUDE_FBE_METADATA_DECRYPT := true (BoardConfig.mk) for metadata-encrypted userdata"),
    (r"Unable to decrypt metadata encryption|Failed to mount data after metadata decrypt",
     "fscrypt_mount_metadata_encrypted() returned failure (or the mount after it failed)", "read the vold lines above it (KeyStorage / KeyUtil / MetadataCrypt) and the fox-diag blocks"),
    (r"Unhandled flag: '([^']+)'",
     "an fstab flag the recovery does not know", "harmless (reservedsize=, checkpoint=fs and similar)"),
    (r"E\s+KeyStorage\.cpp:\d+\] key mkdir /tmp/keymaster_key_blob/: File exists",
     "the second and later key upgrades find the RAM directory already there", "harmless"),
    (r"Upgrading key: ",
     "the Keymaster trusted app asked for the key blob to be upgraded (the recovery reports a fake high OS patch level)",
     "expected; the upgraded blob stays in /tmp, nothing is written to /metadata or /data"),
]

PANIC_RE = re.compile(r"Unable to handle kernel (paging request|NULL pointer)[^\n]*|Kernel panic - not syncing[^\n]*|Internal error: [^\n]*|"
                      r"BUG: KASAN[^\n]*|Freepointer corrupt[^\n]*|Poison overwritten[^\n]*|BUG kmalloc-\d+[^\n]*|Oops[: ][^\n]*")
WAIT_RE = re.compile(r"Decrypt: waiting for the decryption services \((\d+)s\): ([^\n]*)")


def collect(paths):
    files = []
    for p in paths:
        if os.path.isdir(p):
            for dp, _dn, fn in os.walk(p):
                for n in fn:
                    if n in NAMES or n.startswith("recovery") and n.endswith(".log"):
                        files.append(os.path.join(dp, n))
        elif os.path.isfile(p):
            files.append(p)
    return sorted(set(files))


def read(path):
    text = open(path, errors="replace").read()
    return re.sub(r"\x1b\[[0-9;]*m", "", text)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    files = collect(sys.argv[1:])
    if not files:
        print("no log files found under", " ".join(sys.argv[1:]))
        return 2
    texts = {f: read(f) for f in files}
    alltext = "\n".join(texts.values())
    print("files read:")
    for f in files:
        print("  %s (%d lines)" % (f, texts[f].count("\n")))

    print("\nstage table")
    seen = {}
    for label, rx in STAGES:
        m = re.search(rx, alltext)
        seen[label] = m
        extra = (" -> %s" % m.group(1)) if (m and m.groups() and m.group(1)) else ""
        print("  %-52s %s%s" % (label, "PASS" if m else "not seen", extra))

    props = {}
    getprop = [t for f, t in texts.items() if f.endswith("getprop.txt")]
    for t in getprop:
        for m in re.finditer(r"^\[([^\]]+)\]: \[([^\]]*)\]", t, re.M):
            props[m.group(1)] = m.group(2)
    for m in re.finditer(r"fox-diag: ([A-Za-z0-9_.\-]+)=(.*)", alltext):
        props.setdefault(m.group(1), m.group(2).strip())
    if props.get("fox.decrypt.state") or props.get("ro.crypto.fs_crypto_blkdev"):
        print("\nproperties: fox.decrypt.state=%s  ro.crypto.fs_crypto_blkdev=%s  crypto.ready=%s  vendor.sys.listeners.registered=%s" % (
            props.get("fox.decrypt.state", "?"), props.get("ro.crypto.fs_crypto_blkdev", "?"), props.get("crypto.ready", "?"),
            props.get("vendor.sys.listeners.registered", "?")))

    waits = WAIT_RE.findall(alltext)
    not_running = []
    if waits:
        sec, line = waits[-1]
        print("\nlast 'Decrypt: waiting' line (%ss):" % sec)
        for kv in line.split():
            k, _, v = kv.partition("=")
            flag = ""
            if k.startswith("init.svc.") and v != "running" and re.search(r"servicemanager|keystore|qseecomd|keymaster|keymint|gatekeeper|weaver|logd", k):
                flag = "   <-- not running"
                not_running.append(k[len("init.svc."):])
            print("    %-40s %s%s" % (k, v or "-", flag))

    print("\nsignatures that matched")
    hit = 0
    for rx, meaning, todo in SIGNATURES:
        ms = re.findall(rx, alltext)
        if ms:
            hit += 1
            print("  * %s  [%d line(s)]\n      meaning: %s\n      do:      %s" % (rx[:70], len(ms), meaning, todo))
    if not hit:
        print("  none")

    panics = PANIC_RE.findall(alltext)
    plines = [m.group(0) for m in PANIC_RE.finditer(alltext)]
    if plines:
        print("\nkernel oops / panic lines found (%d); first three:" % len(plines))
        for l in plines[:3]:
            print("   ", l[:200])
        print("   -> a kernel panic is not a decryption problem: read recovery-boot-debugging (pstore, slub signature).")

    # verdict
    ok_data = bool(seen["/data decrypted and mounted"])
    has_prep = bool(seen["prepdecrypt ran (props, crypto.ready=1)"])
    print("\nverdict")
    if ok_data:
        user = "the user's password stage was also reported" if seen["user password accepted"] else "the password stage is not in these logs (type the password, then collect again)"
        print("  /data was decrypted by the recovery (%s). %s." % (seen["/data decrypted and mounted"].group(1), user))
        return 0
    attempted = seen["metadata decrypt started"] or has_prep or re.search(r"Decrypt: waiting|fox\.decrypt\.state=", alltext)
    if not attempted and seen["recovery UI started"]:
        print("  no decryption attempt is logged at all. That is what a nocrypt image (or a build without TW_INCLUDE_CRYPTO) looks like.")
        print("  On a FULL image it means the decrypt code never started: check TW_INCLUDE_CRYPTO / TW_INCLUDE_CRYPTO_FBE in the build, that the")
        print("  twrp.flags /data line carries fileencryption=..., and that the command line has androidboot.dynamic_partitions=true on a")
        print("  dynamic-partition device (the common init trigger starts prepdecrypt only when ro.crypto.state=encrypted and that property is true).")
        print("  (keystore2 / VINTF lines in such a log only say that hwservicemanager has no framework manifest; they matter for the full image.)")
    elif re.search(r"Failed to get ServiceManager|Cannot find entry android\.hidl\.manager", alltext):
        print("  keystore2 cannot start: the ramdisk lacks the framework VINTF manifest (system/etc/vintf/manifest.xml).")
    elif re.search(r"RPMB_INIT failed|SSD_INIT failed", alltext):
        print("  qseecomd failed its mandatory RPMB/SSD initialisation.")
    elif not_running:
        print("  the chain stalls at: %s (first service not running in the last waiting line)." % ", ".join(not_running))
    elif not has_prep and seen["recovery UI started"]:
        print("  prepdecrypt never ran: no 'prepdecrypt::' lines. Check that the command line has androidboot.dynamic_partitions=true "
              "(dynamic-partition devices), that the decrypt packages are in the image, and that ro.crypto.state became 'encrypted'.")
    elif seen["key requested from Keymaster"]:
        print("  the recovery asked Keymaster for the key and no answer is logged: the HAL/TEE chain is not answering. Read the fox-diag blocks.")
    elif not seen["recovery UI started"]:
        print("  the recovery log stops before the UI started: kernel/ramdisk/display problem, not decryption (see recovery-boot-debugging).")
    else:
        print("  decryption did not complete and no known signature matched: read the log around the last decrypt line.")
    if plines:
        print("  and the logs contain a kernel panic: fix that first.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
