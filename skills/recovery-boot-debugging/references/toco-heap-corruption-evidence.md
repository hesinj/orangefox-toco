# The reference port's heap-corruption trail (RESOLVED on 27 October: the haptics driver, see the end of this file)

A record of what was observed, what was ruled out and what was never settled, so that the next port can start from it. Verified = seen in logs from the phone.

## Facts (verified)
* Phone: Xiaomi Mi Note 10 Lite (toco), SM6150, kernel 4.14.356 (PixelOS), UFS, 8 GB RAM, bootloader unlocked.
* The ROM's own recovery image booted every time. The recovery built here booted in about half of the tries; a variant without the decryption stack (nocrypt) "usually"; images that start `qseecomd` failed more often.
* Four oopses read back from pstore, all the same signature (free pointer of a free kmalloc-512 / kmalloc-1024 object overwritten with high-entropy data, found at the next allocation):
  | uptime | cache | where it was noticed | image |
  |---|---|---|---|
  | 24.2 s | kmalloc-512 | `tee` process, socket buffer (`unix_stream_sendmsg`) | r3 full |
  | 2.67 s | kmalloc-512 | `msm_gem_new_impl` in the display bring-up (`msm_drm_bind`) | r4 full (no MTP) |
  | 1.13 s | kmalloc-512 | `scsi_get_vpd_buf` while the UFS well-known LUNs were scanned (`ufshcd_async_scan`); 0.2 s later a touch driver oops: consequence | r5/r6 full |
  | 5.66 s | kmalloc-1024 | recovery process, 0.4 ms after its first EROFS mount, socket buffer | before the r7 logs |
* Six more consoles read on 27 October (all kernel oopses with a garbage free list, `kmalloc-512` in nearly all): r7 5.66 s; r8 2.14 s and 2.82 s (the second one in pid 1, init killed); r8 2.81 s (pid 1); r8 6.63 s (`recovery`, right after the five EROFS mounts); r8 4.0 s (pid 1, display bring-up); and **a normal Android boot** at 2.69 s (a kworker loading the haptics firmware, a *live* regmap mutex overwritten) and 2.78 s (**`apexd`** killed inside `dm_create`): the failure that Android showed as `bootstrap-apexd-failed` is this corruption, an oops inside apexd. Three were in pid 1 before user space existed.
* With the 1.13 s case: head `0x235ffba3eedc3544`, cache key `0x5c36ef88c3b06a46`; the decoded stored word had a non-zero, non-pointer high half (`0x8096...`).
* The kernel of the ROM (clang 21 + LLD) and our rebuild (clang 12.0.5 + GNU ld 2.27) are the same source and configuration (strings comparison: 12 vs 4 messages of 18,200 differ). Both start with the `performance` cpufreq governor.
* Image history: r3 (decrypt bounded, panic=0, nocrypt twin) -> r4 (no MTP) -> r5 (framework VINTF manifest; decrypt works once, password accepted, then frozen) -> r6 -> r7 (ROM kernel binary, `retain_initrd nokaslr`, schedutil, sensor-reading recorder: 3 of 3 failed) -> r8 (ROM kernel binary, ROM-like command line, LZMA ramdisk 18 MB, passive recorder: booted, decrypted, password, adb pull).
* The r8 session of 25-26 October stayed up 60,893 s (16.9 hours, from the uptime in a later diagnosis bundle) without a freeze: stability *after* a successful boot is good; boot-to-boot stability is still known from one reported boot.
* Boot of r8, for reference: initrd freed 2.1 s, init 4.2/6.3 s, services 6.5-8.4 s, `/data` mounted by 12.4 s, log clean to 48 s.
* The manual probe of the TEE daemon in a nocrypt image froze the phone in one of two runs, right after `DrmLibRpmb: rpmb_init succeeded` (the first thing qseecomd does).
* Memory map of a boot: first RAM block 0x80000000-0x856fffff, kernel 0x80080000-0x82fa6fff, ramdisk placed top-down ending 0x855FF000, `hyp_region` from 0x85700000.

## Ruled out or weakened
* MTP/USB gadget switching (panic at 2.67 s, before USB).
* The decryption services as the *only* cause (panic at 1.13 s, before userspace), but they correlate with the rate.
* A miscompilation of our kernel build as the only cause (the ROM's binary failed in r7 too; r7's other changes confound that).
* Plain hardware faults: the pattern (30 bits of a pointer replaced by random data, only free objects) is not a bit flip, and the ROM's recovery is stable on the same phone.

## Never settled
* Which of the r7 -> r8 changes (passive recorder, stock-like command line without `retain_initrd nokaslr`/schedutil, 18 MB LZMA ramdisk) removed the failures, and whether it is really stable (one session reported).
* The writer. Hypotheses, none proven: (1) the secure world / RPMB traffic of `qseecomd` leaves the UFS device in a state in which the next boot's LUN scan overruns a buffer; (2) `qseecomd` itself makes something write over free memory; (3) a DMA engine or coprocessor writing into memory the device tree does not reserve (high-entropy content fits ciphertext or a crypto/compression engine); (4) ramdisk size/placement.
* Whether a later change in the phone's persistent firmware state (UFS, RPMB, TZ) can make this worse: on the same phone Android itself stopped booting a few days before the port began. **Settled on 27 October: the `bootstrap-apexd-failed` of Android is the same heap corruption** (boot 32: `apexd` killed by an oops in `dm_create`); the ROM's files are bit-identical to the release, the same kernel ran Android until 18 October, and the stock recovery (same kernel and dtb) shows no oops in eleven sessions, so the cause is below the operating system and appeared on 19 October.

## If it comes back (ladder for this specific symptom)
1. Boot the nocrypt image five times and count; boot the ROM's recovery five times and count.
2. Collect pstore after each failure; run `slub_freelist_decode.py` on the registers; look at the *time* (before init = not userspace).
3. Try a full power-off between boots (not only a warm restart) to test the UFS-state hypothesis.
4. Shrink the ramdisk further; drop optional packages.
5. Debug kernel (`recovery-build-environment/references/kernel-build.md`) only then.

## Resolution (27 October)
The writer was the vendor haptics driver `drv260x` (DRV2604 at I2C 0x5a). Its probe fails when the I2C bus is dead (`i2c_geni ...: Bus arbitration lost, clock line undriveable`, `Failed to read register[0x01]: -71`), and its error path then (1) frees with `kfree()` an object that was allocated with `devm_kmalloc()` (KASAN: `double-free or invalid-free in drv260x_probe+0x724`, a 512-byte object, hence the always-`kmalloc-512` victim) and (2) leaves a queued `request_firmware_nowait` callback (`HapticsFirmwareLoad`) that later copies the firmware (`drv2604.bin`, high-entropy bytes) into the freed object (KASAN: `use-after-free ... Write of size 20`). The object has been handed to somebody else by then, so random kernel memory is overwritten. Every saved console shows the I2C error and the failed probe before the first oops; the stock recovery's logs show the bus working in older sessions and dead from one session on 19 October, the day the phone stopped booting. Repair without rebuilding: `initcall_blacklist=drv260x_driver_init` on the kernel command line (the symbol is in the release kernel). The method that found it: warm resets (`qcom,force-warm-reboot`) to keep the console, a debug kernel (KASAN + `slub_debug=FZPU`), and comparing **what failed first** in every saved console instead of looking at who crashed.
