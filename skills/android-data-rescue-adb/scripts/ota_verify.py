#!/usr/bin/env python3
"""ota-verify.py: is the system that the phone stores exactly what the ROM zip ships?

Rebuilds the partition images of a block-based FULL OTA zip (PART.new.dat or PART.new.dat.br plus PART.transfer.list: the
format of most custom ROMs for phones with dynamic partitions) and compares the SHA-256 of each rebuilt image with the hash
the phone computed over the same partition (android-boot-diagnose.sh, section 15, "logical partitions"). Nothing is stored:
the compressed stream is read from a local file or by HTTP range requests, decompressed, hashed and thrown away, so a 3 GB zip
needs no disk space.

  ota-verify.py ZIP_OR_URL --hashes android-diag/15-storage-read.txt
  ota-verify.py ZIP_OR_URL --sha system=4b959f74...e574 --sha vendor=8dfbbecb...2194 --parts system,vendor
  ota-verify.py ZIP_OR_URL --list

IDENTICAL = the phone holds, bit for bit, what the zip installs (an install through RAM and flash did not corrupt anything,
and nothing has changed since). DIFFERENT = something differs: a corrupted write, a modified partition or another build.
Only ascending new/zero/erase commands (a full OTA) are supported; an incremental OTA is reported and skipped. An 'erase'
range is rebuilt as zeros; what the phone holds there is undefined, so a mismatch in a zip that has erase ranges needs a look.
Needs Python 3.8+; brotli streams need the 'brotli' module (pip install brotli). Exit status: 0 all identical, 2 a difference,
3 could not check.
"""
import argparse, hashlib, json, os, re, struct, sys, threading, time, urllib.request, zlib
from concurrent.futures import ThreadPoolExecutor

BLOCK = 4096
CHUNK = 8 << 20


class FileSource:
    def __init__(self, path):
        self.f = open(path, "rb"); self.size = os.path.getsize(path); self.lock = threading.Lock()

    def read(self, a, b):
        with self.lock:
            self.f.seek(a)
            return self.f.read(b - a + 1)


class HttpSource:
    def __init__(self, url):
        self.url = url
        req = urllib.request.Request(url, headers={"Range": "bytes=0-0"})
        with urllib.request.urlopen(req, timeout=120) as r:
            self.url = r.geturl()          # the mirror address after redirects (keeps its token)
            cr = r.headers.get("Content-Range", "")
            if "/" not in cr:
                raise SystemExit("the server does not support range requests (no Content-Range)")
            self.size = int(cr.split("/")[1])

    def read(self, a, b):
        last = None
        for k in range(8):
            try:
                req = urllib.request.Request(self.url, headers={"Range": "bytes=%d-%d" % (a, b)})
                with urllib.request.urlopen(req, timeout=120) as r:
                    data = r.read()
                if len(data) == b - a + 1:
                    return data
                last = "short read %d of %d" % (len(data), b - a + 1)
            except Exception as ex:
                last = repr(ex)
            time.sleep(2 + k)
        raise SystemExit("could not read bytes %d-%d: %s" % (a, b, last))


def open_source(s):
    return HttpSource(s) if re.match(r"https?://", s) else FileSource(s)


def read_directory(src):
    """Entries of the zip's central directory: name -> dict(method, csize, usize, lho)."""
    tail = src.read(max(0, src.size - 262144), src.size - 1)
    i = tail.rfind(b"PK\x05\x06")
    if i < 0:
        raise SystemExit("not a zip file (no end-of-central-directory record)")
    _, _, _, _, n_total, cd_size, cd_off, _ = struct.unpack("<IHHHHIIH", tail[i:i + 22])
    if cd_off == 0xFFFFFFFF or n_total == 0xFFFF:
        j = tail.rfind(b"PK\x06\x07")
        _, _, z64, _ = struct.unpack("<IIQI", tail[j:j + 20])
        z = src.read(z64, z64 + 55)
        _, _, _, _, _, _, _, n_total, _, cd_size, cd_off = struct.unpack("<IQHHIIQQQQQ", z[:56])
    cd = src.read(cd_off, cd_off + cd_size - 1)
    p = 0; ents = {}
    while p < len(cd) and cd[p:p + 4] == b"PK\x01\x02":
        (_, _, _, _, method, _, _, _, csize, usize, nlen, elen, clen, _, _, _, lho) = struct.unpack("<IHHHHHHIIIHHHHHII", cd[p:p + 46])
        name = cd[p + 46:p + 46 + nlen].decode("utf-8", "replace")
        extra = cd[p + 46 + nlen:p + 46 + nlen + elen]
        q = 0
        while q + 4 <= len(extra):
            tag, sz = struct.unpack("<HH", extra[q:q + 4])
            if tag == 1:
                f = extra[q + 4:q + 4 + sz]; k = 0
                if usize == 0xFFFFFFFF: usize = struct.unpack("<Q", f[k:k + 8])[0]; k += 8
                if csize == 0xFFFFFFFF: csize = struct.unpack("<Q", f[k:k + 8])[0]; k += 8
                if lho == 0xFFFFFFFF: lho = struct.unpack("<Q", f[k:k + 8])[0]; k += 8
            q += 4 + sz
        ents[name] = {"method": method, "csize": csize, "usize": usize, "lho": lho}
        p += 46 + nlen + elen + clen
    return ents


def data_offset(src, e):
    h = src.read(e["lho"], e["lho"] + 29)
    if h[:4] != b"PK\x03\x04":
        raise SystemExit("bad local header")
    nlen, elen = struct.unpack("<HH", h[26:30])
    return e["lho"] + 30 + nlen + elen


def member_bytes(src, e):
    off = data_offset(src, e)
    raw = src.read(off, off + e["csize"] - 1)
    return raw if e["method"] == 0 else zlib.decompress(raw, -15)


def member_chunks(src, e, jobs):
    """Yield the member's stored bytes in order, fetching several ranges ahead."""
    off = data_offset(src, e); total = e["csize"]
    rng = [(i, min(i + CHUNK, total) - 1) for i in range(0, total, CHUNK)]
    with ThreadPoolExecutor(max(1, jobs)) as ex:
        futs = []; nxt = 0
        def fill():
            nonlocal nxt
            while nxt < len(rng) and len(futs) < max(2, jobs * 2):
                a, b = rng[nxt]; futs.append(ex.submit(src.read, off + a, off + b)); nxt += 1
        fill()
        while futs:
            data = futs.pop(0).result(); fill()
            yield data


def decompressed(src, name, ents, jobs):
    e = ents[name]
    chunks = member_chunks(src, e, jobs)
    if e["method"] == 8:
        d = zlib.decompressobj(-15)
        for c in chunks:
            yield d.decompress(c)
        yield d.flush()
    elif e["method"] != 0:
        raise SystemExit("%s: unsupported zip compression method %d" % (name, e["method"]))
    else:
        yield from chunks


def payload_stream(src, part, ents, jobs):
    """The partition's new-data stream: PART.new.dat or PART.new.dat.br, decompressed."""
    if part + ".new.dat.br" in ents:
        try:
            import brotli
        except ImportError:
            raise SystemExit("brotli streams need the brotli module: pip install brotli")
        dec = brotli.Decompressor()
        for c in decompressed(src, part + ".new.dat.br", ents, jobs):
            b = dec.process(c)
            if b:
                yield b
        if not dec.is_finished():
            raise SystemExit("%s: the brotli stream ended early (truncated zip?)" % part)
    elif part + ".new.dat" in ents:
        yield from decompressed(src, part + ".new.dat", ents, jobs)
    else:
        raise SystemExit("no %s.new.dat[.br] in the zip" % part)


class Reader:
    def __init__(self, gen):
        self.gen = gen; self.buf = bytearray(); self.eof = False

    def read(self, n):
        while len(self.buf) < n and not self.eof:
            try:
                self.buf += next(self.gen)
            except StopIteration:
                self.eof = True
        out = bytes(self.buf[:n]); del self.buf[:n]
        return out


def parse_transfer_list(text):
    t = text.split("\n")
    ver = int(t[0]); total = int(t[1])
    first = 2 if ver == 1 else 4
    cmds = []
    for line in t[first:]:
        line = line.strip()
        if not line:
            continue
        name, rest = line.split(" ", 1)
        a = [int(x) for x in rest.split(",")]
        cmds.append((name, [(a[1 + 2 * i], a[2 + 2 * i]) for i in range(a[0] // 2)]))
    return ver, total, cmds


def rebuild_hash(src, part, ents, jobs):
    """Returns (sha256 hex, size, notes) of the partition image rebuilt from the zip."""
    ver, total, cmds = parse_transfer_list(member_bytes(src, ents[part + ".transfer.list"]).decode())
    notes = []
    h = hashlib.sha256(); nxt = 0; size = 0
    rd = Reader(payload_stream(src, part, ents, jobs))
    zeros = bytes(1 << 20)
    for name, ranges in cmds:
        if name not in ("new", "zero", "erase"):
            raise SystemExit("%s: transfer list command '%s' (an incremental OTA?): not supported" % (part, name))
        for s, e in ranges:
            if s != nxt:
                raise SystemExit("%s: blocks are not in ascending order (%d after %d): not supported" % (part, s, nxt))
            n = (e - s) * BLOCK
            if name == "new":
                data = rd.read(n)
                if len(data) != n:
                    raise SystemExit("%s: the data stream ended after %d bytes" % (part, size + len(data)))
                h.update(data)
            else:
                if name == "erase" and "erase" not in notes:
                    notes.append("erase")
                left = n
                while left:
                    k = min(left, len(zeros)); h.update(zeros[:k]); left -= k
            nxt = e; size += n
    if nxt != total:
        raise SystemExit("%s: the commands cover %d of %d blocks" % (part, nxt, total))
    if rd.read(1):
        notes.append("the data stream has bytes left over")
    return h.hexdigest(), size, notes


def parse_hashes(path):
    out = {}
    for line in open(path, encoding="utf-8", errors="replace"):
        m = re.match(r"^(\w+) size=(\d+) sha256=([0-9a-f]{64})", line)
        if m:
            out[m.group(1)] = (m.group(3), int(m.group(2)))
    return out


def main():
    ap = argparse.ArgumentParser(description="Compare the partitions of a phone with the images of a block-based full OTA zip.")
    ap.add_argument("zip", help="path or http(s) URL of the ROM zip (the server must support range requests)")
    ap.add_argument("--hashes", help="a diagnosis bundle's 15-storage-read.txt (lines 'system size=N sha256=HEX ...')")
    ap.add_argument("--sha", action="append", default=[], metavar="PART=HEX", help="the phone's hash of one partition (repeatable)")
    ap.add_argument("--parts", help="comma-separated partitions to check (default: all that have a hash)")
    ap.add_argument("--list", action="store_true", help="only list the zip's members")
    ap.add_argument("--jobs", type=int, default=8, help="parallel range requests for the big streams (default 8)")
    a = ap.parse_args()

    src = open_source(a.zip)
    ents = read_directory(src)
    if a.list:
        for n, e in ents.items():
            print("%-48s method %d  %12d stored  %12d size" % (n, e["method"], e["csize"], e["usize"]))
        return 0
    phone = {}
    if a.hashes:
        phone.update(parse_hashes(a.hashes))
    for s in a.sha:
        k, v = s.split("=", 1)
        phone[k] = (v.lower(), None)
    if not phone:
        print("give the phone's hashes with --hashes or --sha PART=HEX", file=sys.stderr)
        return 3
    parts = a.parts.split(",") if a.parts else [p for p in phone if p + ".transfer.list" in ents]
    if not parts:
        print("none of the hashed partitions has a transfer list in the zip", file=sys.stderr)
        return 3
    worst = 0
    for part in parts:
        if part not in phone or part + ".transfer.list" not in ents:
            print("%-12s no hash or no data for it: skipped" % part); worst = max(worst, 3); continue
        t0 = time.time()
        sha, size, notes = rebuild_hash(src, part, ents, a.jobs)
        want, wsize = phone[part]
        same = sha == want and (wsize is None or wsize == size)
        print("%-12s %12d bytes  rebuilt %s  phone %s  %s%s  (%d s)" % (part, size, sha[:16], want[:16],
              "IDENTICAL" if same else "DIFFERENT", (" [" + ", ".join(notes) + "]") if notes else "", time.time() - t0), flush=True)
        if not same:
            worst = max(worst, 2)
    print("verdict:", "every checked partition is bit-identical to the zip" if worst == 0 else
          ("a partition differs from the zip" if worst == 2 else "incomplete: see the lines above"))
    return worst


if __name__ == "__main__":
    sys.exit(main())
