# Troubleshooting

This tree has been built but **never run on the device by its author**. Everything below comes from
logs that users sent back, so please send logs (see "Collecting logs").

## What was seen so far

`fastboot boot` of the first builds (`r1`, `r2`):

* **Mac, first try:** OrangeFox logo for a moment, then the phone went back to the installed system.
* **Windows, second try:** stuck on the OrangeFox logo for good, but `adb` answered and
  `/tmp/recovery.log` could be pulled.

That log (r2) ends like this:

```
Starting the UI...                       <- display, fstab, vendor props: all fine
...
Settings storage is '/data/media'
Using additional fstab for decryption /etc/additional.fstab
I:prepdecrypt::Script complete. Device ready for decryption.
                                         <- nothing after this line
```

So the kernel, `init`, the display and OrangeFox itself were running. The recovery process was blocked inside
the decryption of `/data`, which sits between "logo" and "menu" in OrangeFox's start-up. The logo
is only replaced by the menu after that step returns.

**Second report (`r3`):** the `-nocrypt` image came up and was usable, so the kernel, display, touch, USB, `adb` and
OrangeFox's own UI work on the device. The full image got stuck again, and this time `adb shell` did not work at all
(in `r2` it did), so the whole phone freezes rather than the recovery just waiting. What changed for the full image
between `r2` and `r3` is that the `modem` partition is now mounted, so the Keymaster HAL can load its trusted app.
`tools/toco-probe.sh` run in the `-nocrypt` image showed that **`qseecomd` works** in recovery: RPMB and SSD
initialise, the listeners register and `vendor.sys.listeners.registered` becomes `true`; `libspl`, `libops` and
`libsecureui` are not found and that is harmless. The Keymaster HAL step of that run was inconclusive: the `-nocrypt`
ramdisk lacks four HIDL libraries (`android.hardware.keymaster@3.0/4.0/4.1.so`, `android.hardware.gatekeeper@1.0.so`),
so the HAL failed to link. The probe now supplies them from `tools/probe-libs/`.

### Why decryption can block forever

`/data` of PixelOS (Android 16) uses metadata encryption with a hardware-wrapped key. To open it the
recovery process asks a chain of services, and each waits for the next without a time limit:

```
recovery (vold code) -> keystore2 -> Keymaster 4.1 HAL -> qseecomd -> TrustZone
```

* `qseecomd` must first set up two things as root and refuses to continue if either fails
  (`RPMB_INIT failed` or `SSD_INIT failed` in logcat, tag `QSEECOMD`): the UFS RPMB device (`/dev/sg*`)
  and the `ssd` partition. Only then does it start its listeners and set
  `vendor.sys.listeners.registered`, which is what starts the Keymaster HAL.
* keystore2 waits for the Keymaster HAL to register with `hwservicemanager`.
* If one of these never comes up, OrangeFox used to wait on the splash screen for ever.

Which link failed on the device is **not known yet**. The next builds are made to find out.

## Third report: the freezes and restarts are kernel panics

`pstore` (the kernel's saved log, collected with `toco-logs.bat` after a forced restart) showed what the "freezes" were:

```
[   24.175712] Unable to handle kernel paging request at virtual address ffdeb1dd3ba7e0a6
[   24.175777] Process tee (pid: 753 ...
[   24.175809] pc : __kmalloc_track_caller+0xac/0x2d8
[   24.176146] Call trace: __kmalloc_track_caller  __alloc_skb  alloc_skb_with_frags  sock_alloc_send_pskb
               unix_stream_sendmsg  sock_write_iter  __vfs_write  vfs_write  SyS_write
[   24.176224] Kernel panic - not syncing: Fatal exception
```

The kernel took the next free object of the `kmalloc-512` cache and found its free-list pointer overwritten with
garbage (about 30 bits differ from a valid address, so it is not a single flipped bit): **something wrote into freed
kernel memory (heap corruption)**. `tee`, an innocent bystander that happened to allocate next, was only the
victim. This explains everything seen so far:

* the first `r2` test on a Mac "went back to PixelOS": the default panic behaviour restarts the phone after 5 s, and
  a restart after `fastboot boot` goes to the installed system;
* `r3` has `panic=0` on purpose, so a panic is a frozen screen and a dead `adb`;
* a boot survives about every other time, which is why `-nocrypt` "worked", then froze while probing: the probe was
  not the cause (version 3 died before it had started `qseecomd`).

It is not the decryption chain, and the evidence does not point to broken hardware (a hardware memory fault
would not look like this and PixelOS would suffer from it too).

Who writes into freed memory is not known yet (see the fourth report: it is not MTP).

`r4`/`r5` therefore come in two kinds:

* **release** (`-r4`, `-r5`): the same kernel as `r3`, MTP removed (no gadget switch), `panic=0` kept.
* **debug** (`-r5-debug`): a kernel with KASAN (in the directories most likely to matter) and SLUB debugging
  (`kernel/debug.fragment`), command line `panic=0 kasan_multi_shot slub_debug=FZPU nokaslr`. It is slower, but when
  something writes to freed or out-of-bounds memory it prints the **exact place** (`BUG: KASAN: use-after-free in ...`)
  and who allocated and freed the memory, and the boot keeps going, so `toco-logs.bat` can fetch it over `adb`.
  `-nocrypt` and full variants exist; start with `-r5-debug-nocrypt`.

How to test the debug image (about 10 minutes):

1. `fastboot boot OrangeFox-R12.0_nocrypt-Unofficial-toco-r5-debug.img` (Windows PC, USB cable connected: that
   starts MTP, as before).
2. Wait 2 to 3 minutes (the debug kernel is slow), touch the screen a little, open a menu or two.
3. Run `toco-logs.bat` (no argument). It prints `kernel error lines found: N`. Send the zip it makes either way.
4. If the phone froze: hold Power until it restarts and keep holding Volume-Down so it goes to fastboot (PixelOS
   would use up the saved log), `fastboot boot` the same image again and run `toco-logs.bat` (the zip then holds
   `pstore.txt`, the console of the frozen boot).
5. Repeat 3 or 4 times: the corruption is intermittent.

## Fourth report (`r4`, full image): everything works up to keystore2, and the corruption is not MTP

`r4` (no MTP) was booted on the phone; the log collected afterwards (`toco-logs.bat`) shows two things.

**1. The heap corruption happens without MTP, and very early.** `pstore` held the console of the boot *before* the
one that was logged, and that boot had died at **2.67 s**, inside the display driver's initialisation:

```
[    2.671144] Unable to handle kernel paging request at virtual address 7e5dcb90f3c288
[    2.671224] pc : kmem_cache_alloc_trace+0x94/0x290      lr : msm_gem_new_impl+0x64/0x190
  Call trace: kmem_cache_alloc_trace  msm_gem_new_impl  _msm_gem_new  alloc_reg_dma_buf_v1
              reg_dmav1_init_sspp_op_v4  sde_hw_sspp_init  sde_plane_init  sde_kms_hw_init  msm_drm_bind ...
[    2.671654] Kernel panic - not syncing: Attempted to kill init! exitcode=0x0000000b
```

Same signature as before: the free list of the `kmalloc-512` cache holds garbage. At 2.67 s there is no USB gadget,
no `adbd`, no MTP and no user space at all, so none of those can be the writer; something corrupted kernel memory
during the first seconds of the boot (or a device / the bootloader wrote into memory the kernel was already using).
The USB controller, for instance, was still in the state the bootloader left it in until the kernel reset it at
about 2.65 s, and `fastboot boot` is the one situation in which the bootloader's USB session is live right before the
kernel starts. Two cheap experiments are listed in "Ideas to narrow it down" below. The debug image is meant to
settle it.

**2. The decryption chain works except `keystore2`.** In the boot that survived, `fox-decrypt-diag.log` shows:

```
init.svc.servicemanager / hwservicemanager / vndservicemanager = running      hwservicemanager.ready=true
init.svc.qseecomd = running      vendor.sys.listeners.registered = true       (RPMB and SSD listeners started)
init.svc.keymaster-4-1-qti = running    "TA API Major Version: 4 ... TA Minor Version: 556", registered with hwservicemanager
init.svc.gatekeeper-1-0-qti = running    "Registered android.hardware.gatekeeper@1.0::IGatekeeper/default"
init.svc.keystore2 = restarting          F keystore2: Check failed: serviceManager.get() Failed to get ServiceManager
recovery: Key exists, using: /metadata/vold/metadata_encryption/key  ->  Retrieving key from keymaster  -> waits
```

So qseecomd, the trusted app, the Keymaster HAL and gatekeeper are all fine on this device. `keystore2` aborts
immediately in `initializeKeymasters()` (`system/security/keystore2/src/km_compat/km_compat.cpp`):
`IServiceManager::getService()` returns null. libhidl only hands out the HIDL service manager when
`android.hidl.manager@1.2::IServiceManager/default` is declared in a VINTF manifest, and `hwservicemanager` says
exactly that it cannot find it (`getTransport: Cannot find entry android.hidl.manager@1.2::IServiceManager/default in
either framework or device VINTF manifest`, `Cannot read /system/etc/vintf/manifest.xml`). The ramdisk had no
**framework manifest**; the official `sweet` and `miatoll` OrangeFox trees (same SoC family) ship one.
`keystore2` therefore crash-looped, the recovery waited for it, and the 90 s limit expired.

`r5` adds `recovery/root/system/etc/vintf/manifest.xml`. What happens next is unknown: keystore2 should now start,
the recovery asks it to decrypt the metadata key through the Keymaster HAL, creates the `dm-default-key` device and
mounts `/data`. The decrypt diagnostics now print the recovery's own decrypt steps and keystore2's log lines in
separate sections.

Data safety of that step: the recovery's key storage code (`system/vold/KeyStorage.cpp`) keeps upgraded key blobs in
`/tmp` (RAM) and does not write them back to `/metadata`; the mount is `encrypt: 0 format: 0`.

### Ideas to narrow the corruption down

* **Unplug the USB cable right after `fastboot boot` says OKAY**, wait for the OrangeFox menu on the screen, then
  plug it in again. If the freezes then stop, the bootloader's USB session is involved.
* **Boot a flashed recovery with the key combination** (Power + Volume-Up) instead of `fastboot boot`: no fastboot
  session is live at all. Only when `fastboot boot` has been tried; it replaces the `recovery` partition.
* Boot the debug images and send `toco-logs.bat` output: with `slub_debug=FZPU` a corrupted object is reported with
  the bytes that were written over it (USB or fastboot protocol data would be recognisable) and who allocated and
  freed it.

## Fifth report (`r3-nocrypt` booted after many tries): the panic can come at 1.1 s, and the PixelOS kernel is the same source

The log of a boot that finally came up (`toco-logs.bat`) also carried, in `pstore`, the console of the boot before it,
an `r5`/`r6` full image (its ramdisk was 27.9 MB, "Freeing initrd memory: 27936K"; the good boot was the 24.6 MB
nocrypt image). That boot had died at **1.13 s**, while the kernel was scanning the UFS well-known LUNs:

```
[    1.125862] scsi 0:0:0:49488: Well-known LUN    SKhynix  H9HQ16AFAMMDAR   A108 PQ: 0 ANSI: 6
[    1.126960] scsi 0:0:0:49476: Well-known LUN    SKhynix  H9HQ16AFAMMDAR   A108 PQ: 0 ANSI: 6
[    1.127030] Unable to handle kernel paging request at virtual address 5ffba3eedc3544
[    1.127143] pc : __kmalloc+0xb8/0x2e4      lr : scsi_get_vpd_buf+0x50/0x128
  Call trace: __kmalloc  scsi_get_vpd_buf  scsi_attach_vpd  scsi_probe_and_add_lun  __scsi_add_device
              ufshcd_probe_hba  ufshcd_async_scan  async_run_entry_fn  process_one_work ...
```

200 ms later the touch driver, probing in another async worker, fell over on the same corruption (`WARNING devm_pinctrl_get`,
then a NULL dereference in `goodix_ts_probe`); that second oops is a consequence, not a second bug.

What the registers say: the faulting instruction is the fast path of `__kmalloc` reading the next free pointer of the object
at the head of the per-cpu free list. That head is `0x235ffba3eedc3544`, a value no kernel address can have, and the cache's
hardened-freelist key is `s->random = 0x5c36ef88c3b06a46`. Un-xoring gives a stored word with a non-zero, non-pointer high half
(`0x8096ebc4...` for an object in the linear map): the first eight bytes of a *free* `kmalloc-512` object were overwritten with
high-entropy data by something other than the allocator, and the allocation that took the object found out. The three panics read
back so far (at 24 s, 2.7 s and 1.1 s) are all this one signature; nothing in them points at a user-space component, and
the ones at 1.1 s and 2.7 s are before the kernel has started `init`.

**The PixelOS release kernel is the same source and configuration as the one built here.** The kernel configuration embedded in
both binaries is the same stale "4.14.180" blob (it says `CONFIG_LOCALVERSION="-perf"`, `SDCARD_FS=y`; it describes neither
kernel), so configurations cannot be compared that way. Comparing the readable strings of the two images instead
(`strings`, 13974 messages vs 13975) they differ in 3 and 4 messages; the ICE driver, EROFS, f2fs iostat, dm-bow are in both.
What differs is the toolchain: the shipped PixelOS kernel is built by their CI with clang 21 and LLD, mine with clang 12.0.5 and
GNU ld 2.27. Both start with the `performance` cpufreq governor (`cpufreq_default_governor` returns it in both).

`r7` therefore changes the variables that can be changed without knowing the culprit, all at once:

| Change | Hypothesis it covers |
|---|---|
| kernel binary = PixelOS's release kernel, byte for byte (`prebuilt/Image-pixelos.gz`) | a miscompilation or a layout/timing accident of the clang 12 + GNU ld 2.27 build |
| `retain_initrd` on the command line | something still writing into the memory the bootloader loaded the ramdisk into (the kernel normally frees it to the page allocator at ~0.9 s) |
| `nokaslr` | an address-dependent bug (the linear map is randomised in this kernel); fixed addresses make a boot behave like the one before |
| `schedutil` set from `init` (cpu0 and cpu6) | all eight cores pinned at maximum frequency for the whole session (nothing else in the recovery changes it) |
| black-box header (`/cache/toco-bb/boot-N.log`) | `/proc/iomem`, the ramdisk range from `/proc/device-tree/chosen`, the kernel command line and a copy of the previous boot's panic log (`pstore-before-boot-N.txt`) |

(`r7` froze in all three boots on the phone; see the sixth report. `r8` takes the command-line options and the governor switch out again.)

If a stable run of `r7` is the result, take the variables out one at a time to find which one mattered (the BoardConfig lines
are commented). If it still panics, the next experiments, in order: (1) boot **PixelOS's own** `recovery-toco_20260609_1626.img`
(SourceForge, `fastboot boot`) a handful of times: if that freezes too the cause is the phone or its bootloader, not this tree;
(2) compress the ramdisk with LZMA (`export FOX_LZMA_RAMDISK=true` before `lunch`: 18 MB instead of 28.6 MB, which the
kernel's own `unlzma` source was checked to decode, but it costs a few seconds of boot) to load about as much as PixelOS's 16 MB recovery does; (3) the
debug image, which reports the first bad write.

## Sixth report (`r7`, full image): three boots, three failures, and the first look at memory

Two things were reported with the `r7` logs. PixelOS's own `recovery.img` (SourceForge, same kernel, same dtb) booted every
time on the phone, so the phone and its bootloader are fine and the cause is in this recovery. And `r3-nocrypt` usually boots,
while the full images fail more often.

`/cache/toco-bb` held two black-box logs and the console of the boot before them (`pstore-before-boot-1.txt`):

* **Boot before them: panic at 5.66 s**, in the `recovery` process, 0.4 ms after its first mount of a logical partition
  (`erofs: (device dm-0): mounted`), in a socket buffer allocation. Same signature as the others, in `kmalloc-1024` this time (the
  head of the free list was `0xfe24562114af6b71`, the cache's key `0x81b1f474d2c1320e`; un-xoring leaves a high-entropy value, not
  a pointer, not zero).
* **Boots 1 and 2: the log stops after the header** (uptime 6.4 s). The header is flushed before the first snapshot starts, so both
  boots stopped within about a second of it, with no panic text left in `pstore` (boot 2 found `pstore` empty). That is the time
  `prepdecrypt` and then `qseecomd` start in the full image (the nocrypt image never starts them). `r7`'s snapshot also read the
  CPU frequencies, every thermal zone, the battery and the kernel stacks of blocked tasks; those reads are removed in `r8` because
  they cannot be ruled out as the cause.
* **Where the bootloader puts the ramdisk** (from the header): `linux,initrd-start/end` = `0x83ab6000`-`0x855fec98` (28,609,688 B),
  and `/proc/iomem` says the first RAM block is `0x80000000`-`0x856fffff` (the `hyp_region` starts at `0x85700000`), the kernel image
  `0x80080000`-`0x82fa6fff`. The ramdisk is placed top-down, so its end is the same for every size and its start moves down with its
  size: PixelOS's 16 MB recovery ramdisk starts near `0x84600000`, this one 11.6 MB above the end of the kernel.

Reading it together: the early panics (1.1 s, 2.7 s) and the later ones (5.7 s, 24 s) have the same signature, so they are one
fault that strikes at different times. The failures are rare or absent in the images that do not start the decryption stack, and
frequent in the ones that do; the manual `qseecomd` probe froze one of two runs right after `rpmb_init`; and the 1.1 s panic
happened while the kernel scanned the UFS RPMB well-known LUN (`49476`), the LUN `qseecomd` talks to. One reading that fits all
of it, **not proven**: the secure-world/RPMB traffic of `qseecomd` leaves the UFS device (which a warm reset does not reset) in a
state that makes the next boot's LUN scan overrun a buffer, and the corrupted object is found whenever it is next allocated. Another:
`qseecomd` itself makes the kernel write over memory. Both predict that a recovery that never starts `qseecomd` is as stable as
PixelOS's own.

`r8` takes `r7` apart accordingly: the command line is PixelOS's own plus what this recovery needs (`retain_initrd nokaslr` and
the `schedutil` switch are gone: they did not prevent the failures and are unproven), the black-box recorder reads only procfs,
init properties and the kernel log, and the ramdisk is LZMA-compressed (about 18 MB, close to PixelOS's 16 MB). The kernel is
still PixelOS's own. If `r8` boots reliably, the fault was in one of the things `r7` added or in the ramdisk size; if it fails
about as often as before, the fault is in the decryption stack or below it and the next step is to boot the nocrypt image and
start `qseecomd` by hand (`tools/toco-probe.sh`) with the console in `pstore`.

## Seventh report (`r8`, full image): a boot that works end to end

`toco-logs.bat` taken after a good `r8` boot, before the password was typed, shows the whole chain working (the kernel is
PixelOS's, the ramdisk LZMA: `Freeing initrd memory: 17792K` at 2.1 s; `init` first stage 4.2 s, second stage 6.3 s, USB gadget
11.8 s; no oops, panic or `memory-errors` in the log, which ends at 48 s):

* at 12.4 s `keystore2`, `qseecomd`, the Keymaster 4.1 HAL and the gatekeeper HAL are all running
  (`vendor.sys.listeners.registered=true`, `fox.decrypt.state=done`);
* `/data` is **already mounted** at that point as `/dev/block/dm-5` (f2fs on `dm-default-key`): the recovery unwrapped the
  metadata key through Keymaster, `libfs_mgr` ran `fsck.f2fs -a` on the decrypted device and mounted it read-write, the
  systemwide fscrypt keys and the device-encrypted keys of user 0 were installed (`fscrypt_init_user0`);
* the log lines `Upgrading key: ...keymaster_key_blob` are expected: the recovery reports a fake OS patch level (2099-12-31), the
  Keymaster trusted app asks for the blobs to be upgraded, and the upgraded blobs are written to `/tmp` (RAM) only. The commit to
  `/metadata` or `/data` is commented out in `system/vold/KeyStorage.cpp`, so the keys on disk are not touched;
* then the OrangeFox password page; typing the password unlocked the user's storage and `adb pull` of the internal storage worked
  (user report).

The freeze that `r5` showed after "user 0 decrypted" did not appear in this session. One session says little about
stability: count how many boots in a row come up.

## Eighth report (25-26 October): the installed Android, read tests and two failure shapes

Android has not booted since the morning of 19 October (last normal shutdown 18 October, about 23:14 Iran time: `shutdown-metrics.txt`).
`tools/android-diagnose.bat` (read-only, run from `r8` with `/data` open) produced four bundles; what they establish:

* `boot`, `dtbo` and `recovery` are **sha256-identical to the official PixelOS 20260609_1626 release files** (two sideloads of that ROM on 19 October rewrote them).
* The stored system is intact and readable. Two sessions (25 and 26 October) read **every file** of system, system_ext, vendor, product and odm through the file system
  (8,338 files, 0 read errors), checked **36 APEX packages** with `unzip -t` (0 bad), read every partition except `userdata` raw with `dd` (0 errors; `super`, 9.1 GB, in 17 s) and hashed the five logical
  partitions twice with the caches dropped in between: the hashes are identical across the two reads and across the two sessions. The kernel log shows no storage errors. `misc` holds no command, `/metadata/apex/sessions` is empty,
  there are no root-module folders, and nothing newer than the last shutdown was written to `/data` by Android.
* **Two different failure shapes.** On 25 October at about 11:03 Iran time (the file time of `persist.sys.boot.reason`, converted from the raw RTC of that boot) one boot attempt reached `init`, `apexd --bootstrap` failed and init
  rebooted to the bootloader (`bootloader,bootstrap-apexd-failed`). On 26 October, after OrangeFox's Reboot -> System, the phone **hung on the logo**: init never wrote a reboot reason (the file then held only `reboot,`, written by the recovery) and pstore was empty after the forced restart
  (a long power-button hold is a cold reset on this phone; only panics and watchdog bites keep the console). A deterministic fault would not change shape; the recovery's old random heap corruption is the same family.
* `r8` itself stayed up 60,893 s (16.9 hours) in one session without a freeze.
* UFS: SK hynix H9HQ16AFAMMDAR (rev A108), healthy read speed; the kernel exposes `health_descriptor/life_time_estimation_a`, `_b` and `eol_info`, but they are raw bytes and were lost in the text form of the first bundles (the script now also prints hex; not read yet).

**RAM stress test (26 October, `tools/ram-test.bat`, `memstress` run from `r8`): no error.** 8 workers pinned to the 8 CPUs, 3,480 MiB tested, 480 s, 1,909.5 GiB verified in 348 rounds with the data flushed out of the CPU caches before every read-back,
13 patterns and idle gaps: **0 errors, 0 transient errors**, no oops, panic or out-of-memory kill in the kernel log. Only message that looks like a watchdog: `pm6150_charger: wdog_bark_irq_handler` every 65 s, which is the *charger chip's* watchdog and also appears in the idle recovery (it is in the 17-hour session's log too): not the CPU, not the test.
Temperatures reported by the charger driver at the end: die 55.4-56.0 C, battery 38.5 C. UFS health attributes (hex of the ASCII values the kernel prints): `life_time_estimation_a` = 0x02 (10-20 % of the estimated life used), `_b` = 0x01 (0-10 %), `eol_info` = 0x01 (normal) per the JEDEC UFS definitions: the flash is far from worn out.
Reading: a CPU, cache or RAM that corrupts data under load is unlikely; faults that need the boot's own conditions (fast voltage and frequency changes, coprocessors starting, cold start, a power dip) are not covered by this test. The diagnosis script v3.2 adds the Xiaomi crash partitions (`oops`, `logdump`, `minidump`, `rawdump`), CPU and bus frequencies and read-only `e2fsck` of `persist`, `cust` and `/metadata`.

**Diagnosis v3.2 (26 October, 13:30):** `persist`, `cust` and a RAM copy of `/metadata` pass `e2fsck -fn` (exit 0): no file-system damage there. The CPUs: six cores up to 1.8 GHz and two up to 2.2 GHz, all online, governor `schedutil` (the recovery binary sets it after boot; the kernel default is `performance`), so the RAM test ran with real frequency changes.
**The `minidump` partition holds a crash dump**: header `cigamgol`, a `Raw_Dmp!` table at 0x400 with `md_kmsg` (the ramoops console zone, 2 MiB), `md_pmsg` and `md_HYP_DIAG.BIN`. The kernel log in it is an **Android** session (uptime 17,651 s and later; haptic feedback of the touch screen, Wi-Fi, Bluetooth, PD fast charging at 5.3 A and 8.9 V, a SELinux message from uid 1000), so
the firmware caught a *crash* of Android: a dump is not written by a normal shutdown. The first MiB shows the charger's thermal level rising from 0 to 10 within 13 s at printk time 17,731-17,744 (the phone was hot while fast-charging), later a USB host port failing to enumerate a device (`error -71`, `hub_ext_port_status failed`) and no kernel error. The end of the log (the crash itself) and the hypervisor diagnostics are after the first MiB and were not in the bundle (it kept 1 MiB; the script now keeps 4).
`tools/pull-minidump.bat` copies the first 4 MiB; `tools/minidump_extract.py` parses it (regions, time order, lines that name a problem, last lines).

**The minidump turned out to be old.** The 4 MiB copy (`tools/pull-minidump.bat`, parsed by `tools/minidump_extract.py`) holds a kernel log that ends in a panic: `kernel BUG at mm/slub.c:304!` in `kfree` called from `cJSON_Delete` <- `cJSON_DeleteItemFromObject` <- `update_hw_monitor_info`
<- `input_event` <- `fts_leave_pointer_event_handler` <- `fts_event_handler` (the FocalTech touch interrupt thread `irq/244-fts`), then `Kernel panic - not syncing: Fatal exception` and `Going down for restart now`. But the kernel is **`4.14.190-perf-g7f6bd6b2a3b2`**, the stock MIUI kernel, not the PixelOS kernel (4.14.356) that
the phone has run since 31 May: the crash belongs to the MIUI days (a double free in a MIUI-only input "hw monitor" built on a cJSON library) and nothing newer has overwritten the partition. `update_hw_monitor_info` and the `cJSON_*` functions are **not** in the PixelOS release kernel nor in the rebuild (symbol lists of both), so this bug is not the cause of the recovery's heap corruption or of Android's failures.
The hypervisor diagnostics (`md_HYP_DIAG.BIN`) only repeat `SMMU Virt: Invalid S2CRn value` (routine). So the PixelOS-era failures never left a minidump: no kernel panic that the firmware caught.
Lesson recorded in the skills: compare the kernel version inside a dump with the running ROM's before drawing conclusions.
Next experiment: boot the ROM's *own* boot image from fastboot with only the command line changed (`tools/make-diag-boot.sh`; kernel, ramdisk and dtb byte-identical, `panic=0 softlockup_panic=1 hung_task_panic=1`), so that a kernel panic or lockup freezes with the console in pstore, and compare with the installed boot path.

**Diagnostic boot of the ROM's own boot image (26 October, bundle of 14:13).** `fastboot boot tools/boot-diag.img` gave a black screen and nothing happened; the next `r8` boot found pstore empty. So no kernel panic and no lockup panic
was caught. The black screen says little: a fastboot-booted Android image has no splash hand-over and shows nothing until the boot animation, and the user cannot tell how long it would have taken. The test neither confirms nor excludes a silent freeze.

**The recorder's death window.** `/cache/toco-bb` of the 26 October sessions (boots 9-14 of the `r8` full image, the same kernel as the ROM): boots 9, 10, 11 and 13 died, 12 and 14 lived (12 for its whole 15-minute recording, 14 for as long as it was watched).
The logs of 11 and 13 were read; each is the header plus exactly two snapshots (about 9 KB; boots 9 and 10 are known only by their size, 9.2 KB each, the same as the other two), and in both the last kernel line is `msm-dwc3 a600000.ssusb: Avail curr from USB = 2`
at 11.74 s (boot 11) and 11.49 s (boot 13): the moment `adbd` binds the USB gadget and the PC starts to enumerate the phone. The next snapshot would have been written at about 14 s.
In the surviving boots 12 and 14 the same line is followed 0.09 s later by `Avail curr from USB = 100`, then `USB_STATE=CONNECTED` (+0.18 s) and `CONFIGURED` (+0.21 s), then `logd` clients, erofs mounts (11.9-12.7 s),
the end of the one-shot decryption diagnostic `fox_diag_run` (13.2 s, it runs three `logcat -d`, `dmesg`, `ps` and `ls /dev/sg*` from about 11.9 s) and the recovery setting build properties (13.6 s).
Reading it with care:
* The recorder starts about 7.5 s after kernel start and writes a snapshot every 3 s, so in all four boots the second snapshot happens to fall on the USB start: the last line of a dead boot is not proof that USB killed it.
* What the logs do show: **four dead boots all stopped inside the same window of about 2.7 s (11.5-14.2 s), none earlier or later, while two survivors ran for minutes and hours.** If the hazard were spread evenly over the first 25 s, that would be very unlikely
  (a rough estimate is well below 1 %). It looks like an event in the boot flow that kills about two boots in three. Events in that window: USB gadget start and enumeration, `fox_diag_run`, the recovery's own mounts and partition scan.
* Boots that die before the recorder starts leave no numbered log, so this counts boots that got as far as 7.5 s. A watchdog restart would not leave one either.
* `fox_blackbox.sh` drops the lines of the charger, battery, touch and USB-PD drivers (`smb5_`, `usbpd`, `QG-K`, `ibat_ua`, ...) from the snapshots: exactly the lines a USB or charger event would print. The next recorder must log raw and filter when reading.
* Also seen: `f2fs` mounts `/data` read-write at about 9.1 s after `fsck.f2fs -a` (the checkpoint version rises by one per boot); the decrypt chain is finished (`prepdecrypt=stopped`, `crypto.ready=1`) before the window.

Watchdog and dumps: the device tree sets the APSS watchdog to bark after 20 s without a pet (pet interval 15 s) and the command line carries `androidboot.ramdump=disable`; a hung CPU should therefore end in a restart after roughly 20-25 s without a dump.
Whether a frozen phone ever restarts by itself is not known and is cheap to observe. pstore held the console after the `r7` panic at 5.66 s (kernel panic, then a forced restart) but has been empty after software reboots and after the silent freezes followed by a forced restart; why is not known (a freeze should leave the console in RAM as a panic does).
The kernel messages of the PMIC (`qcom,qpnp-power-on ... Power-on reason / Power-off reason`: hard reset, PS_HOLD, KPDPWR, UVLO, over-temperature) are printed in the first 0.4 s of every boot and were not recorded for the freezes: they tell how the previous run ended.
In every earlier log that carries them the previous power-off reason is `PS_HOLD (MSM Controlled Shutdown)`, never UVLO or over-temperature.

What is still open, in the order it can be tried without a build:
1. Android with no cable at all (not even a charger): the failing attempts may all have had a cable, and the USB start sits in the window above. Costs nothing.
2. What a frozen `r8` looks like from the PC (`adb devices`, `fastboot devices`) and whether it restarts alone within a minute.
3. `r8` nocrypt eight times in a row, written down as ok/frozen: it removes the decrypt stack, `fox_diag_run` and the `/data` mount but keeps USB. Eight clean boots would point at what was removed; the same two in three would point at USB or the phone.
Then, with a build: a recorder that logs raw lines with a flush per line and the PMIC reasons, and variants that delay the USB gadget or drop `fox_diag_run`.

**Second RAM test (26 October, afternoon; the user's report, the output files were not seen).** `ram-test.bat 3 95` and `ram-test.bat 15 75` both printed `memstress: MemAvailable 6961 MiB, testing 5221 MiB in 8 workers (652 MiB each)`: the program caps the percentage at 75, so `95` became `75`, and the launcher now says so. The user reports that both runs finished with no error and that the recovery did not freeze. With the first run (3,480 MiB, 8 minutes) that is three clean runs; the last two covered about three quarters of the free RAM. What they cannot cover: the kernel's and firmware's own memory (about 0.7 GB of the 7.5 GB), the pages a run happens not to get, and anything that exists only at boot (frequency and voltage steps of the memory bus and CPUs, coprocessors starting, a cold start, a USB or charger event). Reading: a fault in the RAM cells is unlikely; the early-boot window of section "The recorder's death window" stays unexplained.

**Bit-for-bit check of the installed system against the ROM zip (26 October).** The zip the user sideloaded on 19 October (`PixelOS_toco-16.2-20260609-1626.zip`, 2,875,991,319 bytes, the size the recovery log shows) was read by HTTP range requests, the five `PART.new.dat.br` streams were decompressed and rebuilt following their transfer lists (all version 4, only ascending `new` commands, no stash, no erase) and hashed without being stored (`tools/ota-verify.py`). The result: **system, system_ext, product, vendor and odm are bit-identical to what the zip ships** (sizes: system 928468992, system_ext 280956928, product 1760288768, vendor 529952768, odm 9342976 bytes; the phone's hashes were the same in four deep bundles and in both reads of each). So the stored system is exactly the official one, and the 3.5 GB of an install that went through the phone's RAM, the decompression and the flash came out without a flipped bit. Damaged or wrongly written system files are ruled out as the cause. The install log also shows that `vendor` is part of the zip (the PixelOS zip carries its own vendor image), so every logical partition plus `dtbo` and `vbmeta` was rewritten on 19 October.

**Bundle of 15:53 (boots 16-19) and what the user reported.** Android started with no cable at all behaved the same (the user's report). After booting `boot-diag.img` and then starting normally, the screen showed the MI logo, it disappeared after a few seconds, the logo came back and stayed (not timed): consistent with one self-reset followed by a hang, not provable. The recorder: boot 16 stopped within about a second of the recorder start (header only, 7.4-8.3 s), boots 17 and 18 stopped between 7.9 s and about 11 s (one snapshot; the last kernel line of boot 18 is at 7.83 s and its snapshot shows `prepdecrypt`, `qseecomd`, the Keymaster HAL and `keystore2` running), boot 19 lived and was still running 28 minutes later when the bundle was taken. Counting boots 9-19 without 15 (its log was rotated away): **7 died, 3 lived**. Deaths: 1 at 7.4-8.3 s, 2 between 7.9 s and the second snapshot's flush (about 11.4 s), 4 at 11.5-14.2 s, none later. Boot 16 stopped long before the USB gadget start (about 11.2-11.7 s) and boots 17 and 18 before or at its very beginning, so USB is not the (only) trigger, and a boot without any cable did not help Android. What all deaths share is the seconds after `qseecomd`, the Keymaster HAL and the decryption start (about 7 s) until the decryption and the first GUI work are done (about 14 s); the ROM's own recovery and the nocrypt image, which start none of it, were the ones that booted reliably in earlier reports (not re-measured since 19 October for nocrypt). The PMIC reasons in the stock recovery's session logs (`last_kmsg*`: `Power-off reason`) are `PS_HOLD` (software restarts) and `KPDPWR_N (Long Power Key Hold)` (the user's forced restarts), never UVLO, over-temperature or a PMIC watchdog. pstore was empty again, the minidump partition still holds only the old MIUI-era dump, and every read test, `e2fsck` result and partition hash is as before.

Next, without a build: the nocrypt image eight times in a row, written down as a sequence. It keeps USB, the GUI and the recorder and removes the decryption services, `fox_diag_run` and the `/data` mount: if it boots eight times out of eight, the trouble is tied to the secure (TrustZone, key storage) path that Android needs too; if it dies about two times in three, it is the boot itself.

**The nocrypt image eight times in a row (26 October, evening; the user's report).** In order: ok, ok, black screen (the user had wiggled the USB cable first), black screen, black screen, ok, black screen, "ok, but the menu did not come". That is 3 clear successes, 4 black screens and 1 doubtful boot: **the nocrypt image, which starts no decryption service, no diagnostic script and no `/data` mount, fails about as often (4-5 of 8) as the full image (7 of 10 recorded boots).** The decryption and TrustZone path, the leading suspect after the 15:53 bundle, is therefore not the cause; the instability is in the boot itself, or in something both images share (kernel, display, GUI, USB, recorder, the way `fastboot boot` hands over). A black screen means the recovery's GUI never appeared. What the recorder's counter and logs of these boots say (how many reached 7.4 s, where the others died) is the next thing to read, and the ROM's own recovery is the control that is missing: eight boots by the key combination (the installed recovery, no fastboot session) and, after that, eight with `fastboot boot`.

**A lead from the stock recovery's own logs: the CPU governor switch (26 October, evening).** The user is sure that the ROM's own recovery boots every time (not counted in this series; the earlier report said the same). Its saved kernel logs show what it does differently: the `recovery` process starts at 3.76 s, the display is unblanked at 3.83 s and the boot is finished by about 4 s, against about 6.6 s for OrangeFox, and then it idles; it never touches the CPU frequency. OrangeFox's start-up routine (`TWFunc::OrangeFox_Startup`, called from `twrp.cpp`) writes the "balanced" governor, `schedutil`, to `cpu0`-`cpu8/cpufreq/scaling_governor` (setting `fox_boot_balance_check`, default 1) while the kernel starts with `performance`, so every OrangeFox boot changes from "all cores at the top frequency" to frequency steps driven by load in the busiest seconds of the boot. The r7 images did the same switch from `init` at `on boot`, and both r7 boots with a log died within one or two seconds of it. The deaths of `r8` (7.4-14.2 s) are in the seconds after that start-up, the rare early panics (1.1 s, 2.7 s) came at the first frequency change of the kernel itself, and the RAM test, which passed, ran later under `schedutil` at full load or idle, never with the moderate load of a boot that makes the CPUs sit at the middle frequency steps. Android's own boot is also a long run of moderate bursts with the vendor scripts and the perf HAL changing governors and boosts. **Hypothesis, not proven:** a marginal frequency/voltage step, or a marginal core (the two big Cortex-A76 cores 6 and 7), that fails at moderate load and not at full load or at idle. It would fit every observation so far (stock recovery fine, OrangeFox about two in three, nocrypt as bad as full, Android always, RAM fine, system files identical).
What can be tested on Android itself, with the ROM's own boot image and only the kernel command line changed (`tools/make-diag-boot.sh`, `fastboot boot`, nothing written): `nr_cpus=6` (the two big cores never exist), `loglevel=0` (the kernel stops printing to the slow serial console; a noisy driver could stall CPUs there), `cpufreq.off=1` (no frequency changes at all; the cores stay where the bootloader left them, slower and without thermal throttling, for a short test only). If one of them lets Android reach the lock screen, that is the repair candidate: the same command line in the flashed `boot` image keeps `/data` untouched. If none does, the next steps are `r9` (OrangeFox without the governor switch) and a CPU frequency sweep from the recovery.

## What r3 changes

* The decrypt step runs in a worker thread and gives up after 90 seconds (property `fox.decrypt.timeout`,
  minimum 10). The OrangeFox menu then comes up (with a password prompt, but without access to `/data`)
  and `adb` keeps working.
* While waiting, `recovery.log` shows the state of every link every 5 seconds
  (`Decrypt: waiting for the decryption services ...`).
* `fox_decrypt_diag.sh` appends, at about 4, 15, 40 and 90 seconds after `prepdecrypt`, and once more when
  the recovery gives up, a block starting with `fox-diag:` to `/tmp/recovery.log` (also
  `/tmp/fox-decrypt-diag.log`): service states, process list with wait channel, device nodes
  (`/dev/qseecom`, `/dev/sg*`, `by-name`), the `QSEECOMD` / keystore / vold lines from logcat and the
  related kernel messages.
* libbase logging of the recovery process (vold's metadata decrypt) now also goes to `recovery.log`.
* The `modem` partition is mounted read-only at `/vendor/firmware_mnt` from `init`. The Keymaster
  library loads its trusted app from that fixed path when the secure world does not have it yet.
* A stale `libops.so` that earlier builds carried in the image is gone. It was left in the build
  output directory after the file had been removed from the tree. The images are now checked against
  the tree (`tools/verify_image.sh`).
* A second image, `-nocrypt`, has no decryption stack at all. If the plain recovery comes up and the
  full one does not, the problem is in the decryption chain and not in the kernel, display or touch.

The source changes to OrangeFox are in `patches/0001-toco-startup-hardening.patch`.

## Probing the services by hand (needs the `-nocrypt` image)

The `-nocrypt` image does not start the decryption services, but their binaries are in its ramdisk.
`tools/toco-probe.sh` starts them one by one in the order the full image uses (qseecomd, Keymaster 4.1 HAL, gatekeeper
HAL) and reports for each: still running or not, and the kernel function every thread sleeps in. While it runs it
**streams** the relevant logcat and kernel-log lines to the console, announces every step before it runs and prints a
line per second while a HAL starts, so that a freeze or restart shows exactly where it happened. It never touches
`/data`, `/metadata` or a key, and does not call the HALs. The four missing libraries go to `/tmp/probe-libs` (RAM);
nothing under `/system` is written.

```
adb shell mkdir -p /tmp/probe-libs
adb push probe-libs/. /tmp/probe-libs/
adb push toco-probe.sh /tmp/toco-probe.sh
adb shell sh /tmp/toco-probe.sh
adb pull /tmp/toco-probe.log
```

`tools/toco-probe.bat` does all of this on Windows (`toco-probe.bat qseecomd` runs only step 1).

**First probe results.** Run 1 passed (qseecomd up at about 20 s of uptime, no freeze). Run 2 froze the phone; the last
log line on the PC was `DrmLibRpmb: rpmb_init succeeded! with ret = 0`, which is the first thing qseecomd does, so the
freeze was in or right after qseecomd's start-up (the console can lag a little behind, which is why the probe now polls
instead of streaming through a buffer). A freeze that happens only sometimes points at timing or at the state of the
UFS / secure-world side, not at a missing file.

**After a freeze, keep the kernel's last words.** Every line the probe prints is also written to `/dev/kmsg`, so it is in
the kernel's persistent log (pstore, `ramoops_memreserve=4M` is on the command line). Hold Power + Volume-Down until the
phone restarts and keep holding Volume-Down so it goes to fastboot instead of booting PixelOS (PixelOS would consume the
log), boot the `-nocrypt` image again and run `toco-logs.bat`: `pstore.txt` then holds the console of the frozen boot,
with the probe's step markers between the kernel's own messages.

Reading the result:

| Result | Meaning |
|---|---|
| `qseecomd is NOT running` | the first mandatory step failed; the streamed lines (`RPMB_INIT failed`, `SSD_INIT failed`, ...) say which |
| `qseecomd runs but never reported its listeners as registered` | it is stuck inside a listener start |
| `the Keymaster HAL exited` | qseecomd is fine; the HAL could not load its trusted app or register (see its output) |
| the phone freezes or restarts during step 2 | starting the HAL (loading the Keymaster trusted app) crashes the secure world or the kernel |
| all three `yes` | the services themselves are fine; the stall is above them (keystore2 or the recovery's own decrypt call) |

## Collecting logs

Boot the image first (the phone in fastboot mode):

```
fastboot boot OrangeFox-R12.0-Unofficial-toco-r3.img
```

**Windows:** copy `tools/toco-logs.bat` next to `adb.exe` and run it (`toco-logs.bat recovery.img` boots the
image first, then collects twice). It leaves a folder and a zip on the Desktop.
If `adb devices` stays empty while the phone shows the logo, Windows has no driver for the phone in
recovery mode: install the Google USB driver or the Xiaomi USB driver.

**macOS / Linux:** `tools/toco-capture.sh recovery.img` does the same and writes to `~/toco-logs/`.

**By hand**, from any shell with `adb`:

```
adb shell "dmesg > /tmp/dmesg.txt; logcat -d -b all -v threadtime > /tmp/logcat.txt; getprop > /tmp/getprop.txt; ps -A > /tmp/ps.txt"
adb pull /tmp/recovery.log
adb pull /tmp/dmesg.txt
adb pull /tmp/logcat.txt
adb pull /tmp/getprop.txt
adb pull /tmp/ps.txt
```

## Reading `recovery.log`

| Line / block | Meaning |
|---|---|
| `Starting the UI...` and `Atomic Commit succeed` | display works |
| `prepdecrypt::Script complete` | `crypto.ready=1` was set, the service chain should now start |
| `Decrypt: waiting for the decryption services (Ns): ...` | the chain is still not ready; see which `init.svc.*` is not `running` |
| `init.svc.qseecomd=stopped` and logcat `QSEECOMD ... RPMB_INIT failed` / `SSD_INIT failed` | `qseecomd` quit; check the `/dev/sg*` and `by-name/ssd` lines of the block |
| `init.svc.qseecomd=running`, `vendor.sys.listeners.registered` empty | listeners did not finish |
| `vendor.sys.listeners.registered=true`, `init.svc.keymaster-4-1-qti` not `running` | Keymaster HAL did not start or crashed; look at logcat for its message |
| everything `running` but still waiting | keystore2 or the trusted app in TrustZone does not answer |
| `Successfully decrypted metadata encrypted data partition` | `/data` is open |

## What the phone does and what it means

| Phone | Meaning |
|---|---|
| OrangeFox menu with internal storage visible | decryption works |
| OrangeFox menu with a password prompt | decryption of the metadata layer works, the user key needs the lock-screen credential |
| OrangeFox menu after about 90 s, "Decryption services did not answer in time" | the recovery works; send `recovery.log` and `fox-decrypt-diag.log` |
| Stuck on the logo for more than 3 minutes, `adb` answers | the decrypt step is stuck; send the logs |
| Frozen on the logo, `adb` silent, buttons dead | a kernel panic (all builds use `panic=0`): hold Power until it restarts, keep Volume-Down held to land in fastboot, boot again and run `toco-logs.bat`; `pstore.txt` holds the panic |
| Restarts into the installed system | something reset the phone (watchdog, or a panic on a build without `panic=0`); tell what you saw |
| Fastboot screen | `init` hit a fatal error and rebooted to the bootloader |

## Copying files off the phone (Windows)

With `/data` decrypted, `adb pull /sdcard E:\backup` copies the internal storage. On Windows it can stop with
`adb: error: failed to create directory '...': Invalid argument`: Android allows names that Windows does not (`| ? * : " < >`,
a trailing dot or space, paths over 260 characters), and `adb pull` gives up at the first *empty* directory it cannot create
(seen with `Android\data\...\LuckyPatcher\Modified\...|...`). Everything after that point in the copy is missing, so a
pull that ended with this error is incomplete.

`tools/toco-pull-sdcard.bat <folder>` (run it in a Command Prompt, not PowerShell) copies the top-level **files** in one `tar`
stream (unpacked by Windows' own `tar.exe`, so names with spaces or non-Latin letters survive), then every top-level **folder**
except `Android` with its own `adb pull` (a folder that fails is retried one level down, so only the item Windows cannot store is
lost), then `Android\media`. `Android\data` and `Android\obb` (private folders of apps, where such names usually live) are left
out. It reads only from the phone, writes `pull-report.txt` into the destination and ends by comparing the file count on the phone
with the one on the PC. macOS and Linux have no such restriction.

The first version of the script listed the names with `ls` and then failed on every top-level file with a space or a non-Latin
letter in its name: the recovery's `ls` escapes such names (`\ `, `\330\257`), so the name handed to `adb pull` did not exist. Do not
build name lists from `ls` output; `find` prints names raw, and a tar stream does not need the names at all.

## Data safety

`fastboot boot` writes nothing to the phone. While `/data` is not decrypted nothing can be read from
internal storage over `adb` or MTP, and **Format Data / Wipe in the menu would destroy it**. Do not use
them. To copy files off the phone meanwhile, boot the installed system normally.
