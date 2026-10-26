#!/usr/bin/env python3
"""Read a Qualcomm "minidump" partition dump (the first few MiB of /dev/block/bootdevice/by-name/minidump) and show what crashed.

usage: minidump_extract.py FILE [--out DIR] [--lines N]

The partition starts with the marker `cigamgol`; at 0x400 `Raw_Dmp!` begins a table of regions that the firmware copied out of RAM when the
phone crashed (watchdog bite, kernel panic): on the reference phone `md_kmsg` (the pstore/ramoops console: the kernel log, 2 MiB), `md_pmsg`
(userspace persistent log) and `md_HYP_DIAG.BIN` (hypervisor diagnostics). Each table entry carries, relative to its name, the data offset
inside the partition (name-0x20), the size (name-0x18) and the RAM address (name-0x10).
It prints the regions, the time span of the kernel log, where the ring buffer wraps, the keywords that name a crash, and the last lines
without battery/haptics chatter. With --out the regions are written as files (kmsg.txt is rotated into time order).
Reads a file only; run it with `python3 -I`.
"""
import os
import re
import struct
import sys


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    opts = {}
    it = iter(argv)
    for a in it:
        if a in ("--out", "--lines"):
            opts[a] = next(it, "")
    for v in opts.values():
        if v in args:
            args.remove(v)
    if len(args) != 1:
        print(__doc__)
        return 2
    data = open(args[0], "rb").read()
    nlines = int(opts.get("--lines") or 60)
    out = opts.get("--out")
    print("file: %d bytes; magic at 0: %r; at 0x400: %r" % (len(data), data[:8], data[0x400:0x408]))
    if data[0x400:0x408] != b"Raw_Dmp!":
        print("no Raw_Dmp! table at 0x400: not a minidump of this layout")
        return 1
    regions = []
    for m in re.finditer(rb"md_[A-Za-z0-9_.]{2,24}", data[0x400:0x800]):
        p = 0x400 + m.start()
        tag, off, _, size, _, base = struct.unpack("<IIIIIQ", data[p - 0x24:p - 0x24 + 28]) if False else (0, 0, 0, 0, 0, 0)
        off = struct.unpack("<I", data[p - 0x20:p - 0x1c])[0]
        size = struct.unpack("<I", data[p - 0x18:p - 0x14])[0]
        base = struct.unpack("<Q", data[p - 0x10:p - 0x08])[0]
        regions.append((m.group().decode(), off, size, base))
    print("\nregions (name, offset in the partition, size, RAM address):")
    for n, off, size, base in regions:
        flag = "" if off + size <= len(data) else "   <- extends beyond this file (%d bytes missing)" % (off + size - len(data))
        print("  %-18s 0x%06x %9d  0x%x%s" % (n, off, size, base, flag))
    if out:
        os.makedirs(out, exist_ok=True)
    for n, off, size, base in regions:
        blob = data[off:off + size]
        if out:
            open(os.path.join(out, n + ".bin"), "wb").write(blob)
        if n == "md_kmsg":
            kmsg(blob, out, nlines)
        else:
            runs = re.findall(rb"[ -~]{6,}", blob)
            print("\n%s: %d readable runs; first lines:" % (n, len(runs)))
            for r in runs[:25]:
                print("   " + r.decode("latin1")[:200])
            if out:
                open(os.path.join(out, n + ".txt"), "w").write("\n".join(r.decode("latin1") for r in runs))
    return 0


def kmsg(blob, out, nlines):
    pat = re.compile(rb"\[\s*(\d+\.\d+)\] ([^\n\x00]*)")
    lines = [(m.start(), float(m.group(1)), m.group(2).decode("latin1")) for m in pat.finditer(blob)]
    if not lines:
        print("\nmd_kmsg: no timestamped kernel log lines found")
        return
    print("\nmd_kmsg: %d lines, timestamps %.3f .. %.3f s (printk time: it does not count suspend)" % (len(lines), min(l[1] for l in lines), max(l[1] for l in lines)))
    # the ring buffer wraps somewhere: find the largest step backwards in time
    seam = None
    worst = 0.0
    for i in range(len(lines) - 1):
        d = lines[i][1] - lines[i + 1][1]
        if d > worst and d > 1.0:
            worst, seam = d, i + 1
    if seam is None:
        ordered = lines
        print("  time runs forward without a jump: the file order is the time order (newest line at the end of the region)")
    else:
        ordered = lines[seam:] + lines[:seam]
        print("  the ring wraps at byte %d of the region (time jumps back by %.1f s there); rotated into time order" % (lines[seam][0], worst))
        print("  oldest line %.3f, newest line %.3f" % (ordered[0][1], ordered[-1][1]))
    noise = re.compile(r"ibat_ua|USBPD|flash_trigger|QG-K|QCOM-STEPCHG|pm6150_charger|ds28e16|fv calibrate|Get prop|batt power supply|power_supply|drv260x|batteryd|batt_verified")
    key = re.compile(r"panic|oops|bug:|watchdog|wdog|bark|bite|unable to handle|hung task|rcu|stall|lockup|segfault|fatal|abort|killed process|out of memory|i/o error|ufshcd|erofs|dm-verity|smmu|xpu|fault|error|fail|Restarting|Power down|reboot|shutdown|thermal|overheat|tsens", re.I)
    hits = [l for l in ordered if key.search(l[2]) and not noise.search(l[2])]
    print("\nlines that name a problem (%d; the last 40):" % len(hits))
    for _, t, x in hits[-40:]:
        print("  %9.3f %s" % (t, x[:220]))
    quiet = [l for l in ordered if not noise.search(l[2])]
    print("\nthe last %d lines without battery/haptics chatter:" % nlines)
    for _, t, x in quiet[-nlines:]:
        print("  %9.3f %s" % (t, x[:220]))
    print("\nthe very last line of all: %s" % (("%.3f %s" % (ordered[-1][1], ordered[-1][2][:200]))))
    if out:
        with open(os.path.join(out, "kmsg.txt"), "w") as fh:
            for _, t, x in ordered:
                fh.write("[%9.3f] %s\n" % (t, x))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
