# SLUB free-list corruption: recognising it and what to do

## Contents
1. The signature
2. Why the victim is innocent
3. Decoding the overwritten word
4. What the reference port saw
5. Candidates, and how each is tested
6. Debug kernel (KASAN + SLUB debug)

## 1. The signature
On a kernel with `CONFIG_SLAB_FREELIST_HARDENED` (Android 4.14): an oops inside the allocator fast path (`__kmalloc`, `__kmalloc_track_caller`, `kmem_cache_alloc_trace`, `kmem_cache_alloc`),
`Unable to handle kernel paging request at virtual address <not a kernel address>`, in a caller that does nothing wrong (a socket buffer, a SCSI VPD buffer, a GEM object, a work item).
The allocator took the next free object from the per-CPU list, decoded its stored next pointer, and the result was garbage: the first eight bytes of a **free** object had been overwritten after it was freed.

## 2. Why the victim is innocent
The corrupted object sits on the free list until somebody allocates from that cache. The task that happens to allocate next (the display driver at 2.7 s, `tee` at 24 s, the UFS scan at 1.1 s, the recovery at 5.7 s) crashes. The time of the oops is when the object was *reused*, not when it was damaged,
and which task crashes says nothing about the writer.

## 3. Decoding the overwritten word
`scripts/slub_freelist_decode.py --head <garbage head> --random <s->random> --obj <object address> [--offset N]`: on 4.14 `stored = next ^ s->random ^ (obj + s->offset)`, so the word that was in memory is `head ^ random ^ (obj + offset)`.
It classifies the result: zero, kernel pointer (then it is a double free, not an overwrite), ASCII (a string was copied into freed memory: it names the writer), small integer (a counter), high-entropy (ciphertext, compressed data, a hash, or a DMA write from a device).
`s->random` and the object address come from registers of the oops (the cache's `random` field is a 64-bit value; a debug kernel prints it; otherwise it can be read from a vmlinux dump of `kmem_cache`). The reference port decoded to a stored word with a non-zero, non-pointer high half (`0x8096...`).

## 4. What the reference port saw
Four oopses, same signature, in kmalloc-512 and kmalloc-1024: 24 s (socket buffer in `tee`), 2.67 s (`msm_gem_new_impl` in the display bring-up), 1.13 s (`scsi_get_vpd_buf` while the UFS LUNs were scanned), 5.66 s (socket buffer in the recovery process right after its first EROFS mount).
Before userspace existed at 1.1 s and 2.7 s, so not USB, MTP, adb or the decryption stack. The values written were high-entropy. The PixelOS release kernel (same source, same configuration, different compiler: clang 21 + LLD vs clang 12.0.5 + GNU ld 2.27) did not make it go away on its own. Details in `toco-heap-corruption-evidence.md`.

## 5. Candidates, and how each is tested (all were open when the port ended)
| candidate | what it predicts | test |
|---|---|---|
| a compiler/linker difference in the kernel build | the ROM's own binary behaves differently from your build | run the ROM's binary unchanged (done: not sufficient alone) |
| a device DMA-ing into memory the kernel considers free (a coprocessor firmware whose reserved-memory map differs from the device tree, a crypto engine, a stale UFS/ICE descriptor) | random data (ciphertext), random time, only when that device is active | does the corruption disappear when the suspect subsystem never starts? Compare `/proc/iomem` reserved ranges with the firmware's expectations; try the ROM's recovery (it started fewer subsystems) |
| UFS device left in an odd state by secure-world RPMB traffic (`qseecomd`) across a warm reset | worse after boots that start qseecomd; the 1.1 s panic happened while the kernel scanned the RPMB well-known LUN | boot a recovery that never starts the TEE daemon repeatedly; a full power-off between boots |
| a large ramdisk placed just below the first firmware-reserved RAM region | size-dependent | shrink the ramdisk (LZMA) |
| something in your own additions (a recorder reading sensors) | appears only with the addition | remove it |
Only the last two were varied successfully on the reference port; the boot became stable after both changed together with the command line.

## 6. Debug kernel (when the ladder is exhausted)
`CONFIG_KASAN` (generic, outline, only for selected directories), `CONFIG_SLUB_DEBUG`, `DEBUG_LIST`, `BUG_ON_DATA_CORRUPTION`, command line `slub_debug=FZPU kasan_multi_shot nokaslr panic=0`: a bad write is reported with the allocation and free stacks and the bytes that were written (USB/network protocol data is recognisable), and the boot continues.
Constraints that bit: the instrumented kernel must stay below the first firmware-reserved region (kernel at 0x80080000, `hyp_region` at 0x85700000: about 86 MiB of image plus bss; instrumenting everything gave 107 MB), so instrument only the directories that matter (`KASAN_ONLY` patch);
the memory cgroup of the build sandbox counts tmpfs: do not build the kernel in `/dev/shm` while soong runs (OOM kill). The kernel build recipe is in `recovery-build-environment/references/kernel-build.md`.
