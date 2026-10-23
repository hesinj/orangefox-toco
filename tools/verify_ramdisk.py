#!/usr/bin/env python3
"""Static checks of an unpacked recovery ramdisk for the toco decrypt stack.

usage: python3 -I verify_ramdisk.py <unpacked-ramdisk-dir>

For each decrypt-related ELF, resolves every DT_NEEDED entry against the library
search path used by the recovery services (/vendor/lib64:/system/lib64) and reports
anything that is missing. This catches an incomplete ramdisk before flashing; it does
not prove that decryption works on a real device.
"""
import os
import re
import subprocess
import sys

root = sys.argv[1]
SEARCH = ["vendor/lib64", "vendor/lib64/hw", "system/lib64", "system/lib64/hw"]
ELFS = [
    "system/bin/qseecomd",
    "system/bin/android.hardware.keymaster@4.1-service-qti",
    "system/bin/android.hardware.gatekeeper@1.0-service-qti",
    "vendor/lib64/hw/android.hardware.gatekeeper@1.0-impl-qti.so",
]
# libraries that qseecomd loads with dlopen() (not in DT_NEEDED)
DLOPENED = ["libGPreqcancel.so", "libdrmfs.so", "libdrmtime.so",
            "libqisl.so", "librpmb.so", "libssd.so"]


def find(lib):
    for d in SEARCH:
        p = os.path.join(root, d, lib)
        if os.path.exists(p):
            return p
    return None


def needed(path):
    out = subprocess.run(["readelf", "-d", path], capture_output=True, text=True).stdout
    return re.findall(r"\(NEEDED\)\s+Shared library: \[(.+?)\]", out)


missing = {}
seen = set()
queue = [os.path.join(root, e) for e in ELFS]
for e in ELFS:
    if not os.path.exists(os.path.join(root, e)):
        missing.setdefault(e, []).append("<the file itself>")
for lib in DLOPENED:
    p = find(lib)
    if p is None:
        missing.setdefault("qseecomd(dlopen)", []).append(lib)
    else:
        queue.append(p)

while queue:
    p = queue.pop()
    if p in seen or not os.path.exists(p):
        continue
    seen.add(p)
    for n in needed(p):
        found = find(n)
        if found is None:
            missing.setdefault(os.path.relpath(p, root), []).append(n)
        else:
            queue.append(found)

print("checked %d ELF files" % len(seen))
if missing:
    print("MISSING dependencies:")
    for k, v in sorted(missing.items()):
        print("  %-60s needs %s" % (k, ", ".join(sorted(set(v)))))
    sys.exit(1)
print("OK: all NEEDED / dlopen'd libraries of the decrypt stack are present in the ramdisk")
