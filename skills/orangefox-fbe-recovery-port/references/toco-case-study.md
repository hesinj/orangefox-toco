# Case study: Xiaomi Mi Note 10 Lite (toco) with PixelOS Android 16 userdata

The reference port. Read it to calibrate expectations (how many iterations, what failed, what the evidence looked like). Every
claim is marked verified (seen in logs from the phone) or not. Repository: https://github.com/hesinj/orangefox-toco, with
`docs/TROUBLESHOOTING.md` holding the raw evidence and `docs/RELEASE_NOTES_r*.md` the per-image notes.

## Contents
1. Starting point
2. Timeline
3. What each finding taught
4. What fixed the boots (and what is still unknown)
5. Numbers worth remembering
6. Mistakes to avoid next time

## 1. Starting point
* Phone: toco, Snapdragon 730G (SM6150), 8 GB RAM, UFS, A-only with a dedicated 128 MiB `recovery` partition, dynamic partitions (`super`),
  boot header v2, bootloader unlocked. No official OrangeFox for it; official trees existed for `sweet` and `miatoll` (same SoC family).
* ROM: PixelOS (Android 16) with `userdata` f2fs, `fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized+wrappedkey_v0`,
  `metadata_encryption=aes-256-xts:wrappedkey_v0`, `keydirectory=/metadata/vold/metadata_encryption`, `fscompress`.
* Stock kernel (MIUI 4.14.117) had no fscrypt v2, blk-crypto or wrapped keys. The ROM ships a 4.14.356 kernel (PixelOS-Devices/android_kernel_xiaomi_sm6150).
* Goal: boot OrangeFox, decrypt `/data` with the user's password, copy files off.
* Build machine: 4 cores, 15 GB RAM, 40 GB disk. Too little: the disk filled during the sync and again during the build (`recovery-build-environment`).

## 2. Timeline
| image | what it was | what the phone did | what the evidence showed |
|---|---|---|---|
| r1, r2 | first full builds, own kernel build (clang 12) | Mac: OrangeFox logo, then back to the installed ROM. Windows: logo forever, adb answered | `recovery.log` ended at `prepdecrypt::Script complete. Device ready for decryption.`: the recovery sat in the metadata decrypt, which waited for ever (verified). The Mac "return to ROM" was most likely a kernel panic with the default 5 s restart (inferred from the later pstore evidence) |
| r3 | decrypt bounded to 90 s with state logging, diag script, `modem` partition mounted at `/vendor/firmware_mnt`, `panic=0`, a `nocrypt` twin | `nocrypt`: booted and usable. `full`: froze, adb dead | the nocrypt image proved kernel, display, touch, USB and adb fine. pstore of a frozen boot: kernel panic at 24 s, `__kmalloc_track_caller`, free list of `kmalloc-512` overwritten with garbage: heap corruption (verified) |
| r4 | MTP removed | the panic still happened, at 2.67 s inside the display driver | corruption is earlier than USB/MTP/user space (verified); and in a boot that survived, the chain was fine up to `keystore2`, which crash-looped: `Check failed: serviceManager.get()` and hwservicemanager `Cannot read /system/etc/vintf/manifest.xml` (verified) |
| r5 | framework VINTF manifest added (fixes keystore2), debug kernel images (KASAN + SLUB debug) built | the full image once came up far enough for the password to be typed (user report); later boots kept failing | the chain works to the end with the manifest (verified in the r8 logs). The debug images were built but never reported on |
| r6 | like r5 (debug nocrypt image, notes) | the full images kept failing; an old `r3-nocrypt` booted after many tries | its pstore held the console of the failed boot before it (an r5/r6 full image): panic at **1.13 s**, during the UFS LUN scan, same signature (verified). The PixelOS kernel and the own build turned out to be the same source and config, different compiler (clang 21 + LLD vs clang 12 + GNU ld 2.27) |
| r7 | kernel = PixelOS release kernel binary; `retain_initrd nokaslr`; schedutil switch; recorder that also read CPU frequencies, thermal zones, battery, kernel stacks | 3 boots, 3 failures (logo, adb dead). `r3-nocrypt` booted "usually", PixelOS's own recovery always booted | boot before them panicked at 5.66 s (kmalloc-1024); two recorder logs stopped within 1-2 s of the first snapshot with no panic text (verified). The extras did not help; the recorder's sensor reads could not be ruled out as a cause (not proven) |
| r8 | PixelOS kernel binary, near-stock command line (+3 androidboot options), **LZMA ramdisk (18 MB instead of 28.6 MB)**, passive recorder | booted; metadata decrypted; password typed; `adb pull` of the internal storage worked | markers in the log: `fscrypt_mount_metadata_encrypted`, `Successfully decrypted metadata encrypted data partition ... dm-5`, `fscrypt_init_user0`, `fox.decrypt.state=done` (verified) |
| r9 | r8 + `initcall_blacklist=drv260x_driver_init` (the writer into freed memory was the vendor haptics driver, found on 27 Oct) | never booted on its own: r10 contains it | the same parameter in the ROM's own boot image made Android boot with the data intact (verified on the phone); the recovery build carries it and passes the static checks |
| r10 | r9 + MTP built in again (`FOX_EXCLUDE_MTP` opt-out), `patches/0002-toco-mtp-after-decrypt.patch` starts MTP after the password | the owner reports that it works, MTP included (30 Oct; one phone, no logs sent) | static checks (verified): MTP library and its closure in the ramdisk, USB init has `mtp.gs0` + `mtp,adb`, the kernel has `f_mtp`, the patch's log string is in the binary |

Also in the data-copy phase: `adb pull /sdcard` on Windows aborted at a folder name Windows cannot create; solved with a tar stream + per-folder pulls
(`android-data-rescue-adb`).

## 3. What each finding taught
1. **A wait-forever link in the decrypt chain looks like a hang** and leaves an empty log. Bound it, log the state of each service while waiting (the OrangeFox patch).
2. **Isolate with a twin build.** A `nocrypt` image with the same kernel/ramdisk base tells at once whether the kernel and display are healthy.
3. **A "freeze" or "restart into the ROM" can be a kernel panic.** Make it visible (`panic=0`) and recover the log from pstore (`recovery-boot-debugging`).
4. **The framework VINTF manifest is mandatory for keystore2 in a recovery.** The official trees of the same SoC ship it; the first build did not (verified fix).
5. **Qualcomm's TEE stack in recovery needs the firmware partition mounted at `/vendor/firmware_mnt`** because the Keymaster HAL loads its trusted app from that hard-coded path.
6. **Do not read the embedded kernel config** (both kernels embedded the same stale 4.14.180 config): compare by strings and symbols.
7. **Stale files in the staging directories** leaked a removed library and the decrypt init files into the wrong variants until the build script cleaned them.
8. **A diagnostic can be a suspect.** The r7 recorder read sensors; the boots that recorded those reads froze. Keep recorders passive (procfs + kernel log only).
9. **A feature switched off as a precaution is not a feature that failed.** MTP was excluded from r5 on while the panics were unexplained; its one logged error
   was the expected first attempt of the legacy driver. When the real cause is found, put the feature back and say that it is untested.
   And check that a patch is in the binary (`strings`): code in `gui/` guarded by a define that library is not built with disappears silently.
9. **Change variables with a plan.** r7 changed five things and failed; r8 reverted four and changed two, and worked. It is not known which change mattered.
10. **Windows copy pitfalls** (names with `| ? * : " < >`, `ls` escaping, empty-directory aborts) are a data-rescue topic of their own.

## 4. What fixed the boots, and what is still unknown
Between r7 (3/3 failures) and r8 (worked) the differences were: the recorder became passive; `retain_initrd`, `nokaslr` and the schedutil switch were removed
(so the command line is PixelOS's own plus three androidboot options); the ramdisk became 18 MB (LZMA) instead of 28.6 MB. Which of these mattered is **unknown**;
the root cause of the heap corruption is **unproven**. Hypotheses that were never excluded: the secure-world/RPMB traffic of `qseecomd` leaving the UFS device in a
state that corrupts the next boot's LUN scan; `qseecomd` making the kernel write over memory; the ramdisk size / its placement just below the firmware-reserved RAM;
a compiler difference (not excluded: r7 used the PixelOS binary and still failed, but its other changes may have caused that; r8 used the same binary and worked). One good session was reported for r8; the 3-4 boot count
asked for afterwards was not yet known when this skill was written. Treat stability as unproven (`recovery-boot-debugging/references/toco-heap-corruption-evidence.md`).

## 5. Numbers worth remembering
* r8 full image: ramdisk 18.2 MB (LZMA) / 28.6 MB (gzip); `Freeing initrd memory: 17792K` at 2.1 s; init first stage 4.2 s, second stage 6.3 s; USB gadget 11.8 s;
  keystore2, qseecomd, Keymaster HAL and gatekeeper running at 12.4 s, with `/data` already mounted (`dm-5`) by then; log ends at 48 s with no oops.
* The bootloader places the ramdisk top-down, ending at 0x855FF000 (just below the `hyp_region` at 0x85700000); the kernel image sits at 0x80080000.
* Image size: exactly 134217728 bytes (the partition) with an AVB footer from the AOSP test key.
* Builds: about 4 minutes incremental per variant, 11 GB RAM for soong's analysis phase.

## 6. Mistakes to avoid next time
* Do not ship an image whose only evidence is "it built". Run the static checks (`recovery-build-environment/scripts/verify_image.sh`) and say so in the notes.
* Do not stack unproven "precautions" (retain_initrd, nokaslr, governor switches) into a release; each is a new variable on the user's phone.
* Do not build the kernel or a second tree in `/dev/shm` next to a soong build: the sandbox's memory cgroup counts tmpfs and soong was OOM-killed.
* Do not write a diagnostic that touches hardware early in the boot.
* Do not infer that two kernels differ from their embedded configs, and do not call a theory a finding.
* Do not hand over a delete command with a wider scope than the user's sentence.
