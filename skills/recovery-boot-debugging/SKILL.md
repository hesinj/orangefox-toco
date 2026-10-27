---
name: recovery-boot-debugging
description: Diagnose a custom recovery - or an Android phone - that freezes on the logo, restarts into the installed ROM, loses adb, bootloops, or crashes at random times. Collect evidence that survives a freeze (pstore/ramoops console, a passive black-box recorder, one-command log collectors), read an arm64 kernel oops, recognise SLUB heap corruption, compare kernels and ramdisks honestly, and plan experiments that change one variable at a time. Use whenever a boot test fails and the cause is unknown, for example 'stuck on the logo', 'goes back to the ROM', 'adb dead', 'random freeze', 'works one time in two', 'kernel panic', 'pstore', 'last_kmsg', 'bootstrap-apexd-failed', before blaming hardware or rebuilding anything.
---

# Debugging a boot that fails

A phone that does not boot tells you nothing by itself. This skill is about getting evidence out of it, reading the evidence correctly, and not making things worse with the next test.
Written from a port where roughly every second boot of a custom recovery froze (kernel heap corruption, cause never proven), and from a phone whose Android stopped booting. Sibling skills: `orangefox-fbe-recovery-port`, `recovery-fbe-decryption`, `recovery-build-environment`, `android-data-rescue-adb`.
Paths are relative to this skill's directory.

## 1. Classify the symptom first
| what the user sees | usual meaning | evidence to get |
|---|---|---|
| frozen logo, adb silent, buttons dead (with `panic=0`) | kernel panic or hard hang | pstore after a forced restart (section 2) |
| restarts into the installed ROM after a second or two | panic with the default 5 s restart, or a watchdog | same; add `panic=0` to turn it into a freeze that can be read |
| logo forever, adb **answers** | userspace stuck (decrypt chain, GUI) | `/tmp/recovery.log`, `recovery-fbe-decryption` |
| lands in fastboot by itself | init failed and rebooted to the bootloader (Android's `reboot_on_failure ... bootloader`) | the boot reason: `/metadata/bootstat/persist.sys.boot.reason` (e.g. `bootloader,bootstrap-apexd-failed`) and the kernel console in pstore |
| works about one boot in two, any build | random kernel memory corruption or a race | counts per image; pstore of the failures; `references/slub-corruption.md` |
| the same phone fails in different shapes (sometimes a reboot to the bootloader, sometimes a hang on the logo, random oopses) and the stored system reads clean | unstable memory or power; a deterministic software fault would not change shape | `references/ram-stress-test.md` (`scripts/memstress/`) after the cheap checks |
| dead boots in the recorder all stop inside the same few seconds while survivors live for hours | an event in the boot flow kills a share of the boots, not random corruption | `references/death-window-analysis.md` |
| black screen, adb works | display/brightness problem | `dmesg`, `TW_BRIGHTNESS_PATH` |

## 2. Evidence that survives a freeze
* **pstore/ramoops**: the kernel console of the *previous* boot is kept in RAM and shows up as `/sys/fs/pstore/console-ramoops-0` in the next boot, if (a) the kernel has ramoops (`ramoops_memreserve=4M` on the command line,
  appended by the Qualcomm bootloader on the reference phone; check `/proc/cmdline` of a running recovery), (b) the next boot is a **recovery you can read it in, before any other OS boots** (an Android boot in between consumes it) and (c) the reset kept the RAM.
  Protocol after a freeze: hold Power until the phone restarts, **keep Volume-Down held** so it goes to fastboot (not to the ROM), `fastboot boot` the recovery, run the collector. Details: `references/pstore-and-panic-logs.md`.
* **Collectors** (read-only on the phone): `scripts/collect-logs.bat` (Windows, no argument = the phone is up; with an image argument it boots the image first and collects at 30 s and 2 min) and `scripts/collect-logs.sh`
  (macOS/Linux; polls adb while the phone boots, keeps the most complete copy of each log, asks the user what the phone did). They gather `recovery.log`, dmesg, logcat, properties, process list with wait channels, pstore, the recorder's files and
  a memory-error summary.
* **Black-box recorder** `scripts/fox_blackbox.sh` (already in the device-tree template): per boot a header (kernel, command line, `/proc/iomem`, where the bootloader put the ramdisk, a copy of the previous boot's panic log) and every 2-10 s a flushed snapshot to `/cache/fox-bb/boot-N.log`.
  **It must stay passive** (`references/recorder-and-observer-effect.md`). Its snapshots are phase-locked to the boot flow and its noise filter hides charger/USB lines: read dead boots with `references/death-window-analysis.md` before blaming the last line.
* **The Qualcomm `minidump` partition** keeps a copy of the kernel log (and hypervisor diagnostics) of the last crash that the firmware caught; it survives cold resets and days of other boots, which pstore does not. `scripts/pull-minidump.bat` copies 4 MiB, `scripts/minidump_extract.py` shows the regions, the time order and the lines that name a problem (`references/pstore-and-panic-logs.md`, section 6b). Look there first when an *earlier* session crashed.
* **Android's own record** on a ROM that fails to boot: `/metadata/bootstat/persist.sys.boot.reason`, `/data/system/dropbox`, `/data/misc/bootstat`, `/cache/recovery/last_log*` (the ROM recovery's log of its sessions), and whether anything in `/data` is newer than the last shutdown (`android-data-rescue-adb`).

* **A hang may still leave a console, depending on how it is reset**: the power key alone is a hard reset on the reference phone (pstore empty afterwards, seen repeatedly), power plus volume-down together is a warm one (the dtb says so, `references/pstore-and-panic-logs.md`) and the console survives it (it did after a panic once). Do not conclude "no panic" from an empty pstore: a software restart (init's reboot after a failed service, `reboot bootloader`) is a hard reset on such a phone too, and the PMIC lines of the next boot (`Power-off reason: PS_HOLD` with `'cold' boot`) say so; make every restart warm with `WARM=1 scripts/make_diag_boot.sh` (section 1 of the pstore reference). To read a hang make it a panic (`references/ram-stress-test.md`, last section), look at the frozen phone from the PC and keep a live copy of the kernel log (`references/death-window-analysis.md`, section 7).

## 3. Reading it
* `references/pstore-and-panic-logs.md`: how to read an arm64 oops (faulting function and caller, `Process`, the registers), what a `Kernel panic - not syncing` followed by silence means, panic vs. hang.
* A garbage free-pointer in `kmalloc-N` (`Unable to handle kernel paging request` inside `__kmalloc`/`kmem_cache_alloc`, address not a kernel address): `references/slub-corruption.md` and `scripts/slub_freelist_decode.py` (what was written over the object).
* `recovery-fbe-decryption/scripts/analyze_recovery_log.py` for the decrypt stages in a log bundle.

## 4. Experiments (the part that costs the user's time)
`references/triage-ladder.md` has the ladder. Rules in short:
1. **Controls first**: does the ROM's own recovery boot reliably on the same cable and bootloader? Does a nocrypt twin of your image?
2. **One variable per image** when each test is cheap; when tests are expensive, change independent things together *only with a written bisect plan* and a change table. Five changes at once taught nothing on the reference port.
3. **Do not add suspects**: no diagnostic that touches sensors, thermal zones, battery or i2c early in the boot.
4. **Compare kernels by strings, not by their embedded config** (`scripts/compare_kernel_strings.sh`); check an LZMA ramdisk with the kernel's own decoder (`scripts/unlzma_check/`).
5. **Count boots**: five in a row per image, and say "very likely" instead of "fixed".
6. Say plainly what is unproven. The root cause of the reference port's heap corruption was never found (`references/toco-heap-corruption-evidence.md`).

## 4b. Booting the installed ROM's own boot image for diagnosis
`scripts/make_diag_boot.sh BOOT_IMG OUT_IMG` repacks the ROM's boot image so that kernel, ramdisk and dtb stay byte-identical (the dtb too, unless `WARM=1`, which adds the single property `qcom,force-warm-reboot` so that every restart is warm and keeps the console) and only the command line grows (default `panic=0 softlockup_panic=1 hung_task_panic=1 hung_task_timeout_secs=120`: a panic or lockup freezes the phone with the console still in pstore). `fastboot boot OUT_IMG` writes nothing to the phone. It separates three cases: Android boots this way (the fault is in the installed boot path), init fails and the phone lands in the bootloader (pstore holds the reason, but only if that restart was warm: use `WARM=1`), or it stalls without any console (the stall is before the kernel).

## 5. Service-level probing (when the kernel is fine and the TEE chain is suspect)
`scripts/probe_services.sh` starts the TEE daemon, the Keymaster HAL and the gatekeeper HAL one by one in a nocrypt image, streams the relevant log lines to the console and to `/dev/kmsg` (so a freeze leaves the last step in pstore) and reports what is alive.
It never touches `/data`, `/metadata` or a key.

## Files
`references/`: `death-window-analysis.md`, `ram-stress-test.md`, `triage-ladder.md`, `pstore-and-panic-logs.md`, `slub-corruption.md`, `recorder-and-observer-effect.md`, `kernel-ramdisk-comparison.md`, `toco-heap-corruption-evidence.md`
`scripts/`: `collect-logs.bat`, `collect-logs.sh`, `fox_blackbox.sh`, `probe_services.sh`, `slub_freelist_decode.py`, `compare_kernel_strings.sh`, `unlzma_check/`, `memstress/` (RAM stress test: `memstress.c`, `build.sh`, `ram-test.bat`), `minidump_extract.py`, `pull-minidump.bat`, `make_diag_boot.sh`
