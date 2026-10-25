#!/usr/bin/env python3
"""Decode what overwrote the free-list pointer of a free kernel object (CONFIG_SLAB_FREELIST_HARDENED, Linux 4.14 formula).

usage: slub_freelist_decode.py --head 0x235ffba3eedc3544 --random 0x5c36ef88c3b06a46 --obj 0xffffffc0ab12cd00 [--offset 0] [--bits 64]

The oops of a corrupted SLUB cache looks like this (arm64):
    Unable to handle kernel paging request at virtual address 5ffba3eedc3544
    pc : __kmalloc+0xb8/0x2e4
The allocator took object OBJ from the per-cpu free list, read its stored next-free pointer and used the decoded value as the new
list head. The decoded value (--head) is garbage, i.e. the word stored in the *free* object OBJ was overwritten by someone else.

Hardened free pointers (4.14 stable, mm/slub.c freelist_ptr()):   stored = next ^ s->random ^ ptr_addr,   ptr_addr = OBJ + s->offset.
So the word that was really in memory is     stored = head ^ random ^ (obj + offset).
  --head    the garbage head: the register that held the new list head (often the one the faulting load used; the oops "virtual address")
  --random  s->random of that cache (printed by a debug kernel; in a plain oops it is in a register or recoverable from a symbol dump:
            kmem_cache.random). Without it only the shape of the corruption can be judged, see --no-random.
  --obj     address of the object that was just allocated (the one whose first word held the pointer), normally in x0..x28 of the oops
  --offset  s->offset (0 for most caches; non-zero for caches with a constructor or RCU)
The script prints the stored word, its bytes (little endian) as ASCII, and a classification:
  zero          someone cleared the pointer
  kernel-ptr    a valid-looking kernel address: not an overwrite by data, look for a double free / wrong-cache free
  ascii         printable text: a string was copied into freed memory (often names the writer: file names, protocol text)
  high-entropy  looks random: ciphertext, compressed data, a hash, or DMA from a device
  small-int     a counter or length: a stale object still being updated
With --no-random: reports only whether the *head* itself looks like a kernel address (it does not when the stored word was overwritten).
Self-test: python3 slub_freelist_decode.py --selftest
"""
import argparse
import math
import string
import struct
import sys


def classify(word, bits=64):
    b = word.to_bytes(bits // 8, "little")
    if word == 0:
        return "zero", b
    top = word >> (bits - 16)
    if top in (0xFFFF, 0xFFFE, 0xFFFD, 0xFFFC, 0xFFC0, 0xFFC1, 0xFFDF, 0xFF80) or (word >> 40) in (0xFFFFFF, 0xFFFFC0):
        return "kernel-ptr", b
    if all(32 <= x < 127 for x in b if x) and sum(1 for x in b if x) >= 4:
        return "ascii", b
    if word < 1 << 24:
        return "small-int", b
    ent = len(set(b)) / len(b)
    return ("high-entropy" if ent >= 0.75 else "mixed"), b


def decode(head, rnd, obj, off=0, bits=64):
    mask = (1 << bits) - 1
    return (head ^ rnd ^ ((obj + off) & mask)) & mask


def encode(nxt, rnd, obj, off=0, bits=64):
    mask = (1 << bits) - 1
    return (nxt ^ rnd ^ ((obj + off) & mask)) & mask


def selftest():
    rnd, obj = 0x5C36EF88C3B06A46, 0xFFFFFFC0AB12CD00
    nxt = 0xFFFFFFC0AB12CF00
    stored = encode(nxt, rnd, obj)
    assert decode(stored, rnd, obj) == nxt, "round trip"
    # an overwrite with text 'GET /abc' turns into a garbage head; decoding the head returns the text
    text = int.from_bytes(b"GET /abc", "little")
    garbage_head = (text ^ rnd ^ obj) & ((1 << 64) - 1)
    stored2 = decode(garbage_head, rnd, obj)
    assert stored2 == text, "recovered overwrite"
    assert classify(stored2)[0] == "ascii"
    assert classify(0)[0] == "zero"
    assert classify(nxt)[0] == "kernel-ptr"
    print("selftest ok")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--head")
    ap.add_argument("--random")
    ap.add_argument("--obj")
    ap.add_argument("--offset", default="0")
    ap.add_argument("--bits", type=int, default=64)
    ap.add_argument("--no-random", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        selftest()
        return 0
    if not a.head:
        ap.error("--head is required")
    head = int(a.head, 16)
    kind, hb = classify(head, a.bits)
    print("head   0x%0*x  -> %s" % (a.bits // 4, head, kind))
    if kind != "kernel-ptr":
        print("       the new list head is not a kernel address: the stored free pointer was overwritten (a double free or a wrong-cache free would give a kernel address)")
    if a.no_random or not (a.random and a.obj):
        print("pass --random and --obj to recover the overwritten word")
        return 0
    rnd, obj, off = int(a.random, 16), int(a.obj, 16), int(a.offset, 0)
    stored = decode(head, rnd, obj, off, a.bits)
    kind, sb = classify(stored, a.bits)
    print("stored 0x%0*x  -> %s" % (a.bits // 4, stored, kind))
    print("bytes (memory order): %s" % " ".join("%02x" % x for x in sb))
    print("ascii: %s" % "".join(chr(x) if 32 <= x < 127 else "." for x in sb))
    print("entropy: %d distinct byte values of %d" % (len(set(sb)), len(sb)))
    if kind == "high-entropy":
        print("-> random-looking 8 bytes at the start of freed memory: ciphertext / compressed data / hash / a device writing by DMA.")
        print("   Candidates: inline-crypto or crypto-engine buffers, a coprocessor writing into memory the kernel thinks is free (reserved-memory mismatch),")
        print("   a DMA engine with a stale address. Not a plain use-after-free of a kernel object with pointer content.")
    elif kind == "ascii":
        print("-> a string was written into freed memory: grep the kernel for it, it names the writer.")
    elif kind == "zero":
        print("-> the pointer was cleared: memset-after-free or a short write of zeros.")
    elif kind == "kernel-ptr":
        print("-> the stored word is a plausible kernel address: not a data overwrite; suspect a double free or freeing into the wrong cache.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
