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
| black screen, adb works | display/brightness problem | `dmesg`, `TW_BRIGHTNESS_PATH` |

## 2. Evidence that survives a freeze
* **pstore/ramoops**: the kernel console of the *previous* boot is kept in RAM and shows up as `/sys/fs/pstore/console-ramoops-0` in the next boot, if (a) the kernel has ramoops (`ramoops_memreserve=4M` on the command line,
  appended by the Qualcomm bootloader on the reference phone; check `/proc/cmdline` of a running recovery), (b) the next boot is a **recovery you can read it in, before any other OS boots** (an Android boot in between consumes it) and (c) the reset kept the RAM.
  Protocol after a freeze: hold Power until the phone restarts, **keep Volume-Down held** so it goes to fastboot (not to the ROM), `fastboot boot` the recovery, run the collector. Details: `references/pstore-and-panic-logs.md`.
* **Collectors** (read-only on the phone): `scripts/collect-logs.bat` (Windows, no argument = the phone is up; with an image argument it boots the image first and collects at 30 s and 2 min) and `scripts/collect-logs.sh`
  (macOS/Linux; polls adb while the phone boots, keeps the most complete copy of each log, asks the user what the phone did). They gather `recovery.log`, dmesg, logcat, properties, process list with wait channels, pstore, the recorder's files and
  a memory-error summary.
* **Black-box recorder** `scripts/fox_blackbox.sh` (already in the device-tree template): per boot a header (kernel, command line, `/proc/iomem`, where the bootloader put the ramdisk, a copy of the previous boot's panic log) and every 2-10 s a flushed snapshot to `/cache/fox-bb/boot-N.log`.
  **It must stay passive** (`references/recorder-and-observer-effect.md`).
* **Android's own record** on a ROM that fails to boot: `/metadata/bootstat/persist.sys.boot.reason`, `/data/system/dropbox`, `/data/misc/bootstat`, `/cache/recovery/last_log*` (the ROM recovery's log of its sessions), and whether anything in `/data` is newer than the last shutdown (`android-data-rescue-adb`).

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

## 5. Service-level probing (when the kernel is fine and the TEE chain is suspect)
`scripts/probe_services.sh` starts the TEE daemon, the Keymaster HAL and the gatekeeper HAL one by one in a nocrypt image, streams the relevant log lines to the console and to `/dev/kmsg` (so a freeze leaves the last step in pstore) and reports what is alive.
It never touches `/data`, `/metadata` or a key.

## Files
`references/`: `triage-ladder.md`, `pstore-and-panic-logs.md`, `slub-corruption.md`, `recorder-and-observer-effect.md`, `kernel-ramdisk-comparison.md`, `toco-heap-corruption-evidence.md`
`scripts/`: `collect-logs.bat`, `collect-logs.sh`, `fox_blackbox.sh`, `probe_services.sh`, `slub_freelist_decode.py`, `compare_kernel_strings.sh`, `unlzma_check/`
