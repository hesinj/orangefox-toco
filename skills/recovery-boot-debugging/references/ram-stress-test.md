# Testing a phone's RAM from the recovery (memstress)

## Contents
1. When to run it
2. The tool
3. Running it
4. Reading the result
5. What a clean run does and does not say
6. What errors would mean, and what they would not
7. Why pstore could not show a hang

## 1. When to run it
Run it when the same phone fails in **different shapes** and nothing deterministic explains them: random kernel heap corruption in a recovery (`slub-corruption.md`), Android that sometimes reboots to the bootloader (`bootstrap-apexd-failed`) and sometimes hangs on the logo,
oopses in unrelated subsystems at random times, a phone that fails after weeks of working with no software change. One cause that fits all of these is unstable memory (a defective DRAM chip or solder joint, marginal timing or voltage). It is cheap to test and the result removes or confirms a whole class of causes.
Do **not** run it before the cheap checks are done (stored system readable: `android-data-rescue-adb/scripts/android-boot-diagnose.sh`; boot chain identical to the release).

## 2. The tool
`scripts/memstress/memstress.c`: a single static program without libc (so it runs in any recovery, aarch64 for the phone, x86_64 only to test the logic). One process per CPU, each pinned to its CPU, each testing its own region of anonymous memory (default 40 % of `MemAvailable`; `ram-test.bat` uses 50 %; the percentage is capped at 75, a higher number is reduced and the first output line shows the real size, so `95` tests the same as `75`).
Round after round it writes a pattern over the region, **flushes it out of the CPU caches** (so that the read-back comes from DRAM; it probes first and runs without the flush if the CPU refuses the instruction), rests (none, 150 ms, 500 ms in turn: refresh/retention and the memory-bus frequency changes of an idle moment), reads it back and compares.
Patterns: all ones, all zeros, 0xAA, 0x55, walking ones, walking zeros, data-bus checkerboard, address-in-address, pseudo-random and its inverse, and XOR with a second random stream. Every mismatch is read again at once (a value that is correct the second time is a *transient* read error), its physical address is taken from `/proc/self/pagemap`, and the pattern, round, expected and actual values and the failing bit numbers are recorded.
It writes nothing to any file system, sets `oom_score_adj` 1000 for its workers (low memory kills a worker, not adbd), and never touches `/data`.
Build: `scripts/memstress/build.sh [OUTDIR]` (the OrangeFox tree's clang, or any clang with an aarch64 target and lld) writes `memstress-aarch64` and, on an x86_64 host, runs a self test: `--inject` flips one bit and the run must report exactly bit 17 and exit with status 2.

## 3. Running it
Windows: put `memstress-aarch64` and `ram-test.bat` into the platform-tools folder, boot the recovery (no password needed), run `ram-test.bat 8 50` (minutes, percent of free RAM). The result is shown live and saved as `memstress-<time>.txt` on the Desktop, with the kernel lines that may belong to the test.
By hand: `adb push memstress-aarch64 /tmp/memstress; adb shell chmod 755 /tmp/memstress; adb shell /tmp/memstress 8 50`.
Exit status 0 = no error, 2 = errors found, 3 = could not run or a worker died. Use at least 8 minutes; a second run later (the phone warm, then cool) is worth more than one very long run. The most thorough setting is `ram-test.bat 15 75`.

## 4. Reading the result
* `errors: N (transient: M)`: N mismatches. Transient ones read correctly the second time: the bus or the cell is marginal rather than holding a wrong value.
* `by pattern`: errors only in patterns that need many bits to change at once (checkerboard, walking) point at the data bus or at power; errors in all patterns point at the cell array.
* `failing bit positions`: one position repeated = a stuck or weak bit (a pin, a cell); many positions = a bus or power problem; the same few positions in every worker = a systematic fault.
* `pa=...` physical addresses: group them (the summary lists the first 8 per worker). Many errors in one 1 MiB block = a failing row or bank. Compare with `/proc/iomem` (the recorder's header has it) to see which region (kernel image, a reserved region) was involved.
* `WARNING: worker(s) were killed by signal 9`: out of memory kill (lower the percentage); 11: a memory fault (a result in itself in a pure memory test); 4: illegal instruction (tool problem; rerun with `--no-flush`).
* A run during which the phone freezes or restarts is a result: note it, boot the recovery, collect pstore (`pstore-and-panic-logs.md`).

Reference result (Mi Note 10 Lite, 6.8 GiB available, 8 CPUs, 8 minutes, 50 %): 1,909.5 GiB verified, 0 errors; in the same session the kernel printed only a periodic charger-chip watchdog bark that is also there when idle. The phone's boot failures were unexplained after it. A second pair of runs on the same phone, at the cap of 75 % (5,221 MiB of 6,961 MiB available; 3 and 15 minutes), also finished without errors or a freeze (the user's report; the output files were not seen).

## 5. What a clean run does and does not say
A run with no error lowers the odds of a RAM fault; it does not prove there is none. Faults can depend on temperature (a cold phone, or a hot one after minutes of load), on the memory-bus frequency the SoC picks (the test creates both bursts and idle moments), on specific addresses (one run tests at most 75 % of the free RAM, and runs started right after a boot may be handed mostly the same physical pages; kernel and firmware regions are not tested at all), or on power conditions of a full Android boot (many more cores, radios and coprocessors at once).
Say that to the user in those words. Repeat with a higher percentage, a warm phone, and 15 minutes before concluding anything.

## 6. What errors would mean, and what they would not
Errors in this test mean the memory subsystem (DRAM chip, its connection, its timing/voltage configuration) cannot be trusted, whatever the software is. That explains random corruption and hangs of every kind, and **no software change can fix it**: say so, make sure the user's data is copied (`android-data-rescue-adb`), and let them decide about repair (board-level service).
One firmware-level exception exists in principle: stale or damaged DRAM training data kept in a firmware partition (`ddr`, `xbl_config` ...). Do not suggest flashing firmware on that suspicion alone; it needs the exact firmware package of the phone's ROM and the user's explicit consent, and a flash can brick a phone that is only unstable.
Absence of errors means other suspects stay open (power delivery under load, a firmware or TrustZone state, a driver bug triggered by a coprocessor).

## 7. Why pstore could not show a hang
The console of a freeze is only available after a **warm** reset: a kernel panic, or a watchdog bite after a lockup, restarts the SoC with DRAM retained, so ramoops keeps the console. A plain hang followed by the long power-button hold alone is a **hard** (cold) reset on the reference phone and the pstore was empty afterwards; the device tree explains it: power plus volume-down held together is configured as a warm reset (`pstore-and-panic-logs.md`, section 1), and with that combination the console of a hang or of a `panic=0` freeze may well survive. Some of the reference phone's "silent freezes" were probably panics frozen by `panic=0`, restarted with the power key alone, so that the evidence was lost.
To read the log of a hang, the hang has to turn into a panic: boot an image with `softlockup_panic=1 hung_task_panic=1 hung_task_timeout_secs=30` (and `panic=0`), so that a lockup or a stuck task ends in a panic that resets warm. A hang in userspace that is not a stuck task (init waiting for a service) produces no panic: then only a log that is written elsewhere in time helps.
