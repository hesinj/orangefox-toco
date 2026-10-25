#!/usr/bin/env python3
"""Explain, file by file, why a copy of a phone's storage has fewer files than the phone.

usage:
  compare_listing.py PHONE_LIST LOCAL [--root /sdcard] [--local-list] [--windows|--posix] [--max 200]

  PHONE_LIST   text file, one absolute phone path per line (UTF-8): the output of `adb exec-out find /sdcard -type f`
               (pull-sdcard.bat / pull-sdcard.sh write it as DEST/phone-files.txt)
  LOCAL        the folder that holds the copy (walked), or with --local-list a text file of full local paths such as the
               output of Windows `dir /s /b /a-d DEST` (local-files.txt); then give the copy's top folder as --local-root
  --root       the phone folder that was copied (default /sdcard); phone paths are made relative to it
  --windows    apply the Windows file-name rules when explaining (default when LOCAL looks like a Windows path or --local-list is used)

For every phone file that has no counterpart in the copy it prints the likely reason(s):
  invalid character   a name with | ? * : " < > or a control character (Windows cannot create it; adb pull reports "Can't create ...")
  trailing dot/space  Windows silently refuses names that end with '.' or ' '
  reserved name       CON PRN AUX NUL COM1-9 LPT1-9 (also with an extension)
  long path           the full local path reaches 260 characters (the classic Windows limit; long-path support off)
  case collision      another file in the same folder differs only by upper/lower case (Windows folders are case-insensitive)
  unknown             none of the above: look at pull-report.txt, a permission error, a file that changed while copying
It also lists files that exist locally but not on the phone (normally only the report and list files).
Exit status: 0 when nothing is missing, 1 otherwise. Reads text files and folder names only; it never touches the phone.
"""
import os
import sys
import unicodedata

RESERVED = {"CON", "PRN", "AUX", "NUL"} | {"COM%d" % i for i in range(1, 10)} | {"LPT%d" % i for i in range(1, 10)}
BAD_CHARS = set('<>:"|?*') | {chr(i) for i in range(0, 32)}
OWN_FILES = {"pull-report.txt", "phone-files.txt", "local-files.txt"}


def norm(p):
    return unicodedata.normalize("NFC", p)


def windows_reasons(rel, local_root_len, collisions):
    reasons = []
    parts = rel.split("/")
    for part in parts:
        if any(c in BAD_CHARS for c in part):
            reasons.append("invalid character in '%s'" % part)
        if part.endswith((".", " ")):
            reasons.append("trailing dot/space in '%s'" % part)
        if part.split(".")[0].upper() in RESERVED:
            reasons.append("reserved name '%s'" % part)
    if local_root_len + 1 + len(rel) >= 260:
        reasons.append("long path (%d characters with the destination)" % (local_root_len + 1 + len(rel)))
    other = collisions.get(rel.lower())
    if other and len(other) > 1:
        reasons.append("case collision with " + ", ".join(sorted(o for o in other if o != rel)))
    return reasons


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    opts = {}
    it = iter(argv)
    for a in it:
        if a in ("--root", "--local-root", "--max"):
            opts[a] = next(it, "")
    for k in ("--root", "--local-root", "--max"):
        if k in opts and opts[k] in args:
            args.remove(opts[k])
    if len(args) != 2:
        print(__doc__)
        return 2
    phone_list, local = args
    root = (opts.get("--root") or "/sdcard").rstrip("/") + "/"
    maxshow = int(opts.get("--max") or 200)
    local_list = "--local-list" in argv
    windows = ("--windows" in argv or local_list or (len(local) > 1 and local[1] == ":")) and "--posix" not in argv

    with open(phone_list, encoding="utf-8", errors="replace") as fh:
        phone = [norm(l.rstrip("\r\n")) for l in fh if l.strip()]
    phone_rel = []
    for p in phone:
        if p.startswith(root):
            phone_rel.append(p[len(root):])
        elif p.startswith("./"):
            phone_rel.append(p[2:])
        else:
            phone_rel.append(p.lstrip("/"))

    local_rel = set()
    if local_list:
        lroot = opts.get("--local-root")
        if not lroot:
            print("--local-list needs --local-root (the copy's top folder as written in the list)")
            return 2
        lroot_n = norm(lroot.replace("\\", "/").rstrip("/")) + "/"
        with open(local, encoding="utf-8", errors="replace") as fh:
            for l in fh:
                l = norm(l.rstrip("\r\n").replace("\\", "/"))
                if l.lower().startswith(lroot_n.lower()):
                    local_rel.add(l[len(lroot_n):])
        local_root_len = len(lroot)
    else:
        lroot = os.path.abspath(local)
        local_root_len = len(lroot)
        for dp, _dn, fn in os.walk(lroot):
            for f in fn:
                full = os.path.join(dp, f)
                local_rel.add(norm(os.path.relpath(full, lroot).replace(os.sep, "/")))
    local_fold = {x.lower() for x in local_rel} if windows else None

    # case collisions on the phone, per folder
    collisions = {}
    for r in phone_rel:
        collisions.setdefault(r.lower(), set()).add(r)

    missing = []
    for r in phone_rel:
        present = (r in local_rel) or (windows and r.lower() in local_fold and len(collisions[r.lower()]) == 1)
        if not present:
            missing.append(r)
    extra = sorted(x for x in local_rel if x not in set(phone_rel) and os.path.basename(x) not in OWN_FILES)

    print("files on the phone : %d" % len(phone_rel))
    print("files in the copy  : %d (own report/list files not counted: %d)" % (len(local_rel), sum(1 for x in local_rel if os.path.basename(x) in OWN_FILES)))
    print("missing in the copy: %d" % len(missing))
    for r in missing[:maxshow]:
        reasons = windows_reasons(r, local_root_len, collisions) if windows else []
        print("  - %s%s" % (r, ("   <- " + "; ".join(reasons)) if reasons else ("   <- unknown (see pull-report.txt)" if windows or True else "")))
    if len(missing) > maxshow:
        print("  ... %d more (use --max)" % (len(missing) - maxshow))
    if extra:
        print("in the copy but not on the phone: %d" % len(extra))
        for x in extra[:20]:
            print("  + " + x)
    return 0 if not missing else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
