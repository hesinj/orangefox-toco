#!/usr/bin/env python3
"""Static check of an unpacked recovery ramdisk: is the library closure of the decryption stack complete?

usage: python3 -I verify_ramdisk.py ROOT [--elf REL ...] [--require REGEX ...] [--dlopen LIB ...]
                                         [--search DIR ...] [--no-auto] [--all-services] [--strict-strings]

ROOT is the unpacked ramdisk (gzip -dc ramdisk | cpio -idm; lzma -dc for an LZMA ramdisk; or `magiskboot unpack`).

What it checks
  1. The ELF files named with --elf (relative to ROOT) must exist. Unless --no-auto, the binaries of the init `service`
     stanzas whose name or path looks decryption related (qseecomd, keymaster, keymint, gatekeeper, weaver, citadel,
     keystore, vold, tee ...; --all-services takes every service) are checked too. A stanza whose binary is absent is only
     an INFO line: the generic qcom_decrypt init files define keymaster 3.0/4.0/4.1 and gatekeeper variants of which a
     device ships only one. Use --require to insist on the ones this device must have.
  2. --require REGEX (repeatable): at least one ELF in the checked set must have a file name matching the regex.
     Typical Qualcomm call: --require qseecomd --require 'keymaster|keymint' --require gatekeeper
  3. Every DT_NEEDED entry of those ELFs, and of everything they pull in, must be found in the library search path
     (default vendor/lib64, vendor/lib64/hw, system/lib64, system/lib64/hw; 32-bit ELFs use the lib/ twins; --search
     replaces the 64-bit list; paths relative to ROOT). A missing one is an ERROR: the service would die with
     "library X not found".
  4. --dlopen LIB (repeatable) must exist (ERROR). qseecomd loads libraries with dlopen(), invisible to a DT_NEEDED walk.
     Library names that appear as plain strings in a decryption binary, are not DT_NEEDED and are not present are listed as
     WARN (some are optional: toco's qseecomd looks for libspl/libops/libsecureui and runs fine without them).
     --strict-strings turns the warnings into errors.

Exit status: 0 nothing missing (warnings allowed), 1 something missing, 2 nothing to check.
It cannot prove that decryption works on a phone; it catches an incomplete ramdisk before anybody has to boot it.
Pure Python, no binutils (the ELF dynamic section is parsed here); little-endian 32- and 64-bit ELF.
"""
import argparse
import glob
import os
import re
import struct
import sys

DEFAULT_SEARCH = ["vendor/lib64", "vendor/lib64/hw", "system/lib64", "system/lib64/hw"]
SEARCH32 = ["vendor/lib", "vendor/lib/hw", "system/lib", "system/lib/hw"]
CRYPTO_RE = re.compile(r"qseecomd|keymaster|keymint|gatekeeper|weaver|citadel|keystore|vold|trusty|mobicore|tee|prepdecrypt", re.I)
LIBSTR_RE = re.compile(rb"\b(lib[A-Za-z0-9_+.\-]{2,60}\.so)\b")


def parse_elf(path):
    """(needed, is64, raw bytes) of a little-endian ELF file; None when the file is not an ELF."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"\x7fELF" or data[5] != 1:
        return None
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
            p_type, _fl, p_off, p_va, _pa, p_fsz, _msz, _al = struct.unpack_from("<IIQQQQQQ", data, off)
        else:
            p_type, p_off, p_va, _pa, p_fsz, _msz, _fl, _al = struct.unpack_from("<IIIIIIII", data, off)
        if p_type == 1:
            loads.append((p_va, p_off, p_fsz))
        elif p_type == 2:
            dyn = (p_off, p_fsz)
    if dyn is None:
        return [], is64, data

    def v2o(va):
        for vaddr, offset, filesz in loads:
            if vaddr <= va < vaddr + filesz:
                return va - vaddr + offset
        return None

    names, strtab = [], None
    step, fmt = (16, "<qQ") if is64 else (8, "<iI")
    for off in range(dyn[0], dyn[0] + dyn[1], step):
        tag, val = struct.unpack_from(fmt, data, off)
        if tag == 0:
            break
        if tag == 1:
            names.append(val)
        elif tag == 5:
            strtab = v2o(val)
    needed = []
    if strtab is not None:
        for o in names:
            end = data.index(b"\0", strtab + o)
            needed.append(data[strtab + o:end].decode("ascii", "replace"))
    return needed, is64, data


def service_stanzas(root, all_services):
    """{service name: binary path} from every init .rc file found in the ramdisk."""
    rcs = set()
    for pat in ("*.rc", "system/etc/init/*.rc", "vendor/etc/init/*.rc", "system/etc/init/hw/*.rc", "init/*.rc"):
        rcs.update(glob.glob(os.path.join(root, pat)))
    out = {}
    for rc in sorted(rcs):
        try:
            text = open(rc, errors="replace").read()
        except OSError:
            continue
        for m in re.finditer(r"^service\s+(\S+)\s+(\S+)", text, re.M):
            name, path = m.group(1), m.group(2)
            if all_services or CRYPTO_RE.search(name) or CRYPTO_RE.search(os.path.basename(path)):
                out[name] = path
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("root")
    ap.add_argument("--elf", action="append", default=[], help="ELF that must exist, relative to ROOT (repeatable)")
    ap.add_argument("--require", action="append", default=[], help="regex: some checked ELF must have a matching file name (repeatable)")
    ap.add_argument("--dlopen", action="append", default=[], help="library that must exist because something dlopen()s it (repeatable)")
    ap.add_argument("--search", action="append", default=[], help="64-bit library directory relative to ROOT (repeatable, replaces the default)")
    ap.add_argument("--no-auto", action="store_true", help="do not discover ELFs from init service stanzas")
    ap.add_argument("--all-services", action="store_true", help="discover every init service, not only decryption related ones")
    ap.add_argument("--strict-strings", action="store_true", help="treat unresolved library-name strings as errors")
    a = ap.parse_args()
    root = a.root
    search = a.search or DEFAULT_SEARCH

    def find(lib, dirs):
        for d in dirs:
            p = os.path.join(root, d, lib)
            if os.path.exists(p):
                return p
        return None

    errors, warns, infos = {}, {}, []
    seen, strings_seen = set(), {}
    start = []

    for rel in a.elf:
        p = os.path.join(root, rel)
        if os.path.isfile(p):
            start.append(p)
        else:
            errors.setdefault(rel, []).append("<the file itself is missing>")
    if not a.no_auto:
        for name, path in sorted(service_stanzas(root, a.all_services).items()):
            p = os.path.join(root, path.lstrip("/"))
            if os.path.isfile(p):
                start.append(p)
            else:
                infos.append("service %s -> %s: binary not in the ramdisk" % (name, path))
    if not start and not errors:
        print("nothing to check: no ELF named and no decryption-related service with a binary found under", root)
        print("(name the binaries with --elf system/bin/<name>, or use --all-services)")
        return 2

    def walk(queue):
        while queue:
            p = queue.pop()
            if p in seen or not os.path.isfile(p):
                continue
            seen.add(p)
            res = parse_elf(p)
            if res is None:
                continue  # a shell script or a data file started as a service
            needed, is64, data = res
            dirs = search if is64 else SEARCH32
            rel = os.path.relpath(p, root)
            for n in needed:
                f = find(n, dirs)
                if f is None:
                    errors.setdefault(rel, []).append(n)
                else:
                    queue.append(f)
            base = os.path.basename(p)
            if CRYPTO_RE.search(base):
                for m in LIBSTR_RE.finditer(data):
                    s = m.group(1).decode()
                    if s not in needed and s != base:
                        strings_seen.setdefault(s, set()).add(rel)

    walk(list(start))
    for lib in a.dlopen:
        f = find(lib, search) or find(lib, SEARCH32)
        if f is None:
            errors.setdefault("(dlopen)", []).append(lib)
        else:
            walk([f])
    for s, who in sorted(strings_seen.items()):
        if not find(s, search) and not find(s, SEARCH32) and s not in a.dlopen:
            (errors if a.strict_strings else warns).setdefault(", ".join(sorted(who)), []).append(s)

    checked_names = sorted(os.path.basename(p) for p in start)
    for rx in a.require:
        if not any(re.search(rx, n) for n in checked_names):
            errors.setdefault("(--require)", []).append("no checked ELF matches /%s/" % rx)

    print("checked %d ELF files; decryption-related binaries: %s" % (len(seen), ", ".join(checked_names) or "none"))
    for i in infos:
        print("INFO:", i)
    if warns:
        print("WARN: library names that appear as strings but are not present (dlopen candidates, may be optional):")
        for k, v in sorted(warns.items()):
            print("  %-50s %s" % (k, ", ".join(sorted(set(v)))))
    if errors:
        print("MISSING:")
        for k, v in sorted(errors.items()):
            print("  %-60s needs %s" % (k, ", ".join(sorted(set(v)))))
        return 1
    print("OK: every NEEDED library of the decryption stack is present in the ramdisk")
    return 0


if __name__ == "__main__":
    sys.exit(main())
