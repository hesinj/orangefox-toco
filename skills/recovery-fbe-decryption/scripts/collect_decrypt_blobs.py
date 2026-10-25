#!/usr/bin/env python3
"""Collect the vendor binaries and libraries of the /data decryption stack from a ROM and lay them out for a recovery tree.

usage:
  collect_decrypt_blobs.py --vendor-root DIR --out <device-tree>/recovery/root [--source-name TEXT] [--only REGEX]
  collect_decrypt_blobs.py --adb --out <device-tree>/recovery/root                 # pull from the phone running that ROM

DIR is the ROM's vendor partition as a directory: a mounted vendor.img (erofs/ext4), `adb pull /vendor`, or the vendor/ folder of
a proprietary-blob repository. --adb reads /vendor of the connected, booted phone instead (shell user is enough on stock ROMs;
files the shell user cannot read are reported). Nothing is modified in the source.

What it does
  1. finds the decryption binaries in bin/ and bin/hw/: qseecomd (Qualcomm TEE daemon), the Keymaster / KeyMint, Gatekeeper and
     Weaver HAL services (patterns below; --only narrows them, --pattern adds more);
  2. resolves every DT_NEEDED library against lib64/ (or lib/ for 32-bit ELFs) of the same vendor root and copies the closure;
  3. also copies vendor libraries whose names appear as strings inside the daemons (qseecomd dlopen()s libdrmfs, librpmb, libssd ...)
     except the ones in SKIP_OPTIONAL, which pull other stacks in (libops.so drags in the display stack and made earlier builds
     fail); --include-optional copies them anyway;
  4. libraries that are not in the vendor root are classified: AOSP / HIDL interface libraries come from the recovery build itself
     (check with verify_ramdisk.py after the build), anything else is listed as UNRESOLVED for a human.
Layout written under --out (Android 10+ recovery convention): binaries -> system/bin/<name>, libraries -> vendor/lib64/ and
vendor/lib/ (same sub-directories, hw/ included). A provenance note and sha256 list go to <device tree>/port/blobs.txt (two levels above --out).
The files are proprietary: keep their provenance in NOTICE.md and mind the license of the ROM you take them from.
"""
import argparse
import hashlib
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

PATTERNS = [
    r"^qseecomd$",
    r"^android\.hardware\.keymaster@[0-9.]+-service.*$",
    r"^android\.hardware\.gatekeeper@[0-9.]+-service.*$",
    r"^android\.hardware\.weaver@[0-9.]+-service.*$",
    r"^android\.hardware\.security\.keymint-service.*$",       # AIDL KeyMint: unverified territory, see other-socs.md
    r"^android\.hardware\.security\.secureclock-service.*$",
    r"^android\.hardware\.security\.sharedsecret-service.*$",
]
SKIP_OPTIONAL = {"libops.so", "libsecureui.so", "libspl.so"}
AOSP_LIBS = {
    "libc.so", "libm.so", "libdl.so", "liblog.so", "libcutils.so", "libutils.so", "libbase.so", "libc++.so", "libhidlbase.so",
    "libhidltransport.so", "libhwbinder.so", "libhardware.so", "libcrypto.so", "libssl.so", "libbinder.so", "libbinder_ndk.so",
    "libvndksupport.so", "libz.so", "libxml2.so", "libion.so", "libprocessgroup.so", "libselinux.so", "libkeymaster_messages.so",
    "libkeymaster4support.so", "libkeymaster4_1support.so", "libkeystore-attestation-application-id.so", "libpuresoftkeymasterdevice.so",
    "libsoftkeymasterdevice.so", "libhidlmemory.so", "libfmq.so", "libcgrouprc.so", "libcrypto_utils.so", "libgatekeeper.so",
}


def elf_needed(path):
    """DT_NEEDED names and ELF class of a little-endian ELF; ([], None) when it is not an ELF."""
    data = open(path, "rb").read()
    if data[:4] != b"\x7fELF" or data[5] != 1:
        return [], None
    is64 = data[4] == 2
    if is64:
        phoff, = struct.unpack_from("<Q", data, 0x20)
        phentsize, phnum = struct.unpack_from("<HH", data, 0x36)
    else:
        phoff, = struct.unpack_from("<I", data, 0x1C)
        phentsize, phnum = struct.unpack_from("<HH", data, 0x2A)
    loads, dyn = [], None
    for i in range(phnum):
        off = phoff + i * phentsize
        if is64:
            t, _f, o, v, _p, fsz, _m, _a = struct.unpack_from("<IIQQQQQQ", data, off)
        else:
            t, o, v, _p, fsz, _m, _f, _a = struct.unpack_from("<IIIIIIII", data, off)
        if t == 1:
            loads.append((v, o, fsz))
        elif t == 2:
            dyn = (o, fsz)
    if not dyn:
        return [], is64
    strtab, names = None, []
    step, fmt = (16, "<qQ") if is64 else (8, "<iI")
    for off in range(dyn[0], dyn[0] + dyn[1], step):
        tag, val = struct.unpack_from(fmt, data, off)
        if tag == 0:
            break
        if tag == 1:
            names.append(val)
        elif tag == 5:
            for v, o, fsz in loads:
                if v <= val < v + fsz:
                    strtab = val - v + o
    out = []
    for n in names:
        end = data.index(b"\0", strtab + n)
        out.append(data[strtab + n:end].decode("ascii", "replace"))
    return out, is64


def lib_strings(path):
    # lib*.so (qseecomd dlopen()s its helpers) and android.*.so (the gatekeeper service loads its -impl-qti.so HAL implementation)
    return {m.group(1).decode() for m in re.finditer(rb"\b((?:lib|android\.)[A-Za-z0-9_+.@\-]{2,80}\.so)\b", open(path, "rb").read())}


class LocalSource:
    def __init__(self, root):
        self.root = root

    def files(self):
        for dp, _dn, fn in os.walk(self.root):
            for f in fn:
                yield os.path.relpath(os.path.join(dp, f), self.root)

    def get(self, rel):
        return os.path.join(self.root, rel)


class AdbSource:
    def __init__(self):
        self.tmp = tempfile.mkdtemp(prefix="vendor-pull-")

    def files(self):
        out = subprocess.run(["adb", "shell", "find /vendor/bin /vendor/lib64 /vendor/lib -maxdepth 2 -type f 2>/dev/null"],
                             capture_output=True, text=True, check=True).stdout
        for line in out.splitlines():
            line = line.strip().replace("\r", "")
            if line.startswith("/vendor/"):
                yield line[len("/vendor/"):]

    def get(self, rel):
        dst = os.path.join(self.tmp, rel)
        if not os.path.exists(dst):
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            r = subprocess.run(["adb", "pull", "/vendor/" + rel, dst], capture_output=True, text=True)
            if r.returncode != 0:
                print("  cannot pull /vendor/%s: %s" % (rel, (r.stderr or r.stdout).strip()), file=sys.stderr)
                return None
        return dst


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--vendor-root")
    ap.add_argument("--adb", action="store_true")
    ap.add_argument("--out", required=True, help="the recovery/root directory of the device tree")
    ap.add_argument("--only", help="regex: keep only binaries whose file name matches")
    ap.add_argument("--pattern", action="append", default=[], help="extra regex for binary file names (repeatable)")
    ap.add_argument("--include-optional", action="store_true", help="also copy %s" % ", ".join(sorted(SKIP_OPTIONAL)))
    ap.add_argument("--source-name", default="", help="where the blobs come from (ROM name and build), written to port/blobs.txt")
    a = ap.parse_args()
    if bool(a.vendor_root) == a.adb:
        ap.error("give exactly one of --vendor-root and --adb")

    src = AdbSource() if a.adb else LocalSource(a.vendor_root)
    index = sorted(src.files())
    byname = {}
    for rel in index:
        byname.setdefault(os.path.basename(rel), []).append(rel)
    pats = [re.compile(p) for p in PATTERNS + a.pattern]
    bins = [r for r in index if os.path.dirname(r) in ("bin", "bin/hw") and any(p.search(os.path.basename(r)) for p in pats)]
    if a.only:
        bins = [r for r in bins if re.search(a.only, os.path.basename(r))]
    if not bins:
        sys.exit("no decryption binaries found (looked for: %s) under bin/ and bin/hw/ of the vendor root" % ", ".join(PATTERNS))

    chosen, unresolved, aosp, skipped, written = {}, set(), set(), set(), []
    queue = []
    for rel in bins:
        p = src.get(rel)
        if p:
            queue.append((rel, p, "bin"))
    # HIDL passthrough services (android.hardware.<name>@<ver>-service[-variant]) load their implementation by scanning
    # lib64/hw (and lib/hw) for android.hardware.<name>@<ver>-impl*.so: the name is not a string inside the binary
    for rel in bins:
        m = re.match(r"^(android\.hardware\.[a-z0-9_.]+@[0-9.]+)-service(.*)$", os.path.basename(rel))
        if not m:
            continue
        base, variant = m.group(1), m.group(2)
        cands = [r for r in index if re.match(r"^lib(64)?/hw/%s-impl.*\.so$" % re.escape(base), r)]
        pref = [r for r in cands if r.endswith(variant + ".so")] if variant else []
        for r in (pref or cands):
            lp = src.get(r)
            if lp:
                queue.append((r, lp, "lib"))
    seen = set()
    while queue:
        rel, p, kind = queue.pop()
        if rel in seen:
            continue
        seen.add(rel)
        chosen[rel] = (p, kind)
        needed, is64 = elf_needed(p)
        libdir = "lib64" if is64 or is64 is None else "lib"
        want = set(needed)
        if kind == "bin" or os.path.basename(rel) == "qseecomd":
            for s in lib_strings(p):
                if s not in needed and s != os.path.basename(rel):
                    if s in SKIP_OPTIONAL and not a.include_optional:
                        skipped.add(s)
                        continue
                    want.add(s)
        for lib in sorted(want):
            cands = [r for r in byname.get(lib, []) if r.startswith(libdir + "/")] or [r for r in byname.get(lib, []) if r.startswith(("lib64/", "lib/"))]
            if cands:
                lp = src.get(cands[0])
                if lp:
                    queue.append((cands[0], lp, "lib"))
            elif lib in needed:
                (aosp if (lib in AOSP_LIBS or lib.startswith("android.") or lib.startswith("libhidl")) else unresolved).add(lib)

    os.makedirs(a.out, exist_ok=True)
    lines = []
    for rel, (p, kind) in sorted(chosen.items()):
        dst = os.path.join(a.out, "system", "bin", os.path.basename(rel)) if kind == "bin" else os.path.join(a.out, "vendor", rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(p, dst)
        os.chmod(dst, 0o755 if kind == "bin" else 0o644)
        written.append(os.path.relpath(dst, a.out))
        lines.append("%s  %s  (vendor/%s)" % (sha256(dst), os.path.relpath(dst, a.out), rel))
    port = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(a.out.rstrip("/")))), "port")   # <device tree>/port
    os.makedirs(port, exist_ok=True)
    with open(os.path.join(port, "blobs.txt"), "w") as f:
        f.write("Decryption-stack blobs collected by collect_decrypt_blobs.py\nsource: %s\n\n" % (a.source_name or "(not given: fill in ROM name and build)"))
        f.write("\n".join(lines) + "\n")

    print("binaries:")
    for rel in sorted(r for r, (_p, k) in chosen.items() if k == "bin"):
        print("  system/bin/%s   (from vendor/%s)" % (os.path.basename(rel), rel))
    print("libraries copied (%d):" % sum(1 for _r, (_p, k) in chosen.items() if k == "lib"))
    for rel in sorted(r for r, (_p, k) in chosen.items() if k == "lib"):
        print("  vendor/%s" % rel)
    if skipped:
        print("skipped on purpose (optional, they pull other stacks in; --include-optional to copy): %s" % ", ".join(sorted(skipped)))
    if aosp:
        print("expected from the recovery build, not from the ROM (verify with verify_ramdisk.py after the build): %s" % ", ".join(sorted(aosp)))
    if unresolved:
        print("UNRESOLVED (not in the vendor root and not an AOSP/HIDL name): %s" % ", ".join(sorted(unresolved)))
        print("  -> look for them in the ROM's /system/lib64 or /system_ext/lib64 and add them by hand")
    print("provenance and sha256 list: %s" % os.path.join(port, "blobs.txt"))
    return 1 if unresolved else 0


if __name__ == "__main__":
    sys.exit(main())
