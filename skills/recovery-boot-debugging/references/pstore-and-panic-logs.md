# pstore, ramoops and reading a kernel panic

## Contents
1. How pstore keeps the log
2. Getting it out
3. panic=0 and why it matters
4. Reading an arm64 oops
5. Hang vs panic
6. When pstore is empty
7. Other persistent logs on Android phones

## 1. How pstore keeps the log
`ramoops` reserves a block of RAM (4 MiB on the reference phone at 0xb0000000, the command line item `ramoops_memreserve=4M` that the Qualcomm bootloader appends; the kernel logs
`pstore: Registered ramoops as persistent store backend` and `ramoops: attached 0x400000@0xb0000000` at about 0.25 s). The console driver writes every kernel message into it as it is printed, so the last lines before a freeze or panic are in RAM.
After a **warm reset** (watchdog, panic restart, the long-press power reset on the reference phone) the content survives and the next kernel exposes it under `/sys/fs/pstore/console-ramoops-0` (`dmesg-ramoops-0` for oops dumps).
It is lost if the next boot is an OS that consumes it (Android's `pstore` handling, the ROM recovery that saves it to `/cache/recovery/last_kmsg`), after a full power cycle, or when the battery is pulled.

## 2. Getting it out
1. After the freeze hold Power until the phone restarts, keep Volume-Down held so it enters fastboot.
2. `fastboot boot` a recovery that can show `/sys/fs/pstore` (the recorder copies it at boot to `/cache/fox-bb/pstore-before-boot-N.txt`: survives even if the user reboots again).
3. `collect-logs.bat` / `collect-logs.sh`: `pstore.txt` holds the console of the frozen boot; the recorder files hold the headers.
4. `ls -la /sys/fs/pstore` empty = no record: say so, do not guess.
`/cache/recovery/last_kmsg*` of an AOSP-style ROM recovery is **that recovery's own console of its session**, not the previous boot's (verified on the reference phone: it ends where the recovery session ended).

## 3. panic=0 and why it matters
With the kernel's default panic timeout (5 s on the reference kernel) a panic restarts the phone: after `fastboot boot` it lands in the installed ROM, the freeze is invisible, and the pstore content may be consumed by that boot. `panic=0` on the command line makes a panic a frozen screen:
the user can tell a panic from other failures, and nothing consumes the log. Take it out for a release once the recovery is stable. (`CONFIG_QCOM_FORCE_WDOG_BITE_ON_PANIC=y` on the reference kernel forces a watchdog bite on panic; with `panic=0` the phone still froze rather than reset.)

## 4. Reading an arm64 oops
```
[    1.127030] Unable to handle kernel paging request at virtual address 5ffba3eedc3544      <- the address the load used
[    1.127143] pc : __kmalloc+0xb8/0x2e4      lr : scsi_get_vpd_buf+0x50/0x128                <- faulting function, its caller
  Call trace: __kmalloc  scsi_get_vpd_buf  scsi_attach_vpd  scsi_probe_and_add_lun  ...       <- who asked for memory
[    1.127...] Process kworker/u16:2 (pid: 56 ...)                                             <- the victim, not necessarily the culprit
[    ...      ] Kernel panic - not syncing: Fatal exception
```
* The faulting address tells the class: a **kernel-looking address** (0xffffffc0...) = ordinary null/stale pointer bug; a **non-canonical or random-looking address** inside an allocator = the allocator found garbage = memory corruption (`slub-corruption.md`).
* The function at `pc` is where the damage was *noticed*. For allocator faults the culprit wrote earlier, to freed memory, and an innocent task paid.
* Several oopses 100-200 ms apart: the first one counts; later ones in other workers are consequences.
* Time stamp = seconds since the kernel started: 1 s = during device probing (UFS/SCSI scan), 2.7 s = display driver, 5-6 s = init/recovery start, 24 s = user space. Same signature at different times = one random fault, not several bugs.
* `Internal error: Oops: 96000004` is the ESR class (data abort); `x0..x28` hold the objects involved; with a debug kernel the report names the allocation and free stacks.
* Symbolising needs the matching `System.map`/vmlinux; the oops already carries `symbol+offset` for kernels with kallsyms.

## 5. Hang vs panic
* Panic: `Kernel panic - not syncing` is the last or near-last line in pstore.
* Hang without panic: the log simply stops. Typical: a driver waiting on hardware (e.g. UFS RPMB command, a remote processor), a lock-up. `echo w > /proc/sysrq-trigger` (blocked tasks) and `echo l` (all CPUs) before the phone dies are in the collectors, but only help when adb still answers.
* Watchdog: `msm_watchdog` / `wdog bite` lines, or none at all and the phone restarts by itself.

## 6. When pstore is empty
The next boot was not a recovery that shows it; RAM was not retained (full power-off, long battery drain); the kernel never got to register ramoops (died in the bootloader or before 0.25 s); `/sys/fs/pstore` is not mounted in that recovery (`mount -t pstore pstore /sys/fs/pstore`).
An empty pstore after a failure that reached the ROM's init is evidence in itself: the failure may be in userspace.

## 6b. The Qualcomm minidump partition: a second copy of the console
On Qualcomm phones the firmware copies selected RAM regions into the `minidump` partition when the phone **crashes** (watchdog bite, kernel panic) and `ro.boot.ramdump` is `disable` (minidump, not a full RAM dump). Verified on the reference phone (Mi Note 10 Lite): the partition began with `cigamgol`, at 0x400 `Raw_Dmp!` and a table of three regions:
`md_kmsg` (the ramoops console zone, 2 MiB: the **kernel log**), `md_pmsg` (3 KB of userspace persistent log) and `md_HYP_DIAG.BIN` (8 KB hypervisor diagnostics at 0x858c9000). The regions follow the table in the partition (about 2 MiB in all). `scripts/minidump_extract.py FILE` lists them, finds the ring-buffer seam by timestamps and prints the lines that name a problem and the last lines before the end.
Why it matters: **it survives what pstore does not.** Pstore is lost after a cold reset or when another boot consumes it; the minidump stays in flash until the next crash overwrites it. On the reference phone the partition held the kernel log of an Android session (touch haptics, Wi-Fi, Bluetooth, fast charging, a message from uid 1000), which pstore could never show because that session ended days earlier. Pull 4 MiB with `scripts/pull-minidump.bat` (or `adb exec-out "dd if=/dev/block/bootdevice/by-name/minidump bs=1048576 count=4" > minidump.bin`).
A dump exists only if the last crash was caught by the firmware: a hang followed by a long power-button hold leaves none, and the dump is overwritten by the next crash. Other partitions of the same family (`oops`, `logdump`, `rawdump`, `dbg`) were all zeros on the reference phone.

## 7. Other persistent logs on Android phones
* `/cache/recovery/last_log*`, `last_kmsg*` (ROM recovery sessions), `last_install`, `.UPDATED` marker files (a block OTA was applied) and their timestamps (the recovery's clock is the raw RTC: on the reference phone about 55 years off).
* `/metadata/bootstat/persist.sys.boot.reason`: init's last reboot reason. Android init can send the phone to the bootloader on failures with reasons like `bootstrap-apexd-failed`.
* `/data/system/dropbox` (crashes), `/data/system/shutdown-checkpoints/*` (who shut the phone down and why), `/data/misc/bootstat/*`, tombstones.
* Vendor partitions on some phones: on the reference phone `minidump` held a crash dump (section 6b); `oops`, `logdump`, `rawdump` and `dbg` were all zeros.
