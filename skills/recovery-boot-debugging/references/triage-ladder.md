# Triage ladder for an unstable boot

Each rung is a cheap experiment whose result removes a whole class of causes. Do them in order; do not skip to the expensive ones (debug kernels, rebuilding the kernel).

## Contents
1. The ladder
2. How to run an experiment on a tired user
3. Bisect plans (several suspects, expensive tests)
4. What the reference port's ladder looked like
5. Stop conditions

## 1. The ladder
| rung | experiment | what a pass proves | what a fail proves |
|---|---|---|---|
| 0 | the **ROM's own recovery** (or any known-good image) via `fastboot boot`, several times | cable, driver, bootloader and the phone's hardware boot the same kernel reliably | the phone or its bootloader is the problem, not your image |
| 1 | your **nocrypt** image (same kernel, ramdisk base, cmdline, no TEE/HAL/keystore2 start) | kernel, display, touch, USB, adb and the OrangeFox UI are fine | the cause is in the kernel/ramdisk/cmdline/board setup; decryption is innocent |
| 2 | your **full** image | the whole stack boots | with rung 1 passing: the decryption stack (or what it triggers) is the cause; probe it (`probe_services.sh`) |
| 3 | swap **one** variable: the kernel binary (ROM's own vs own build), `FOX_ALT_KERNEL=true` | the kernel binary mattered | it did not |
| 4 | swap the **command line** to the ROM recovery's own plus what the recovery needs | the extra options mattered | they did not |
| 5 | shrink the **ramdisk** (`FOX_LZMA_RAMDISK=true`: 35% smaller; remove optional packages) | size/placement mattered (the bootloader places it just below the first firmware-reserved RAM region) | it did not |
| 6 | remove **your own additions** (recorder, services you added) | an addition was the suspect | not that |
| 7 | **debug kernel** (KASAN + SLUB debugging, `slub_debug=FZPU`) | prints the first bad write with allocation/free stacks | expensive: kernel build with the matching compiler, memory limits below the hypervisor region |
Rung 7 was prepared (images exist in the history of the reference repository) but never needed: rungs 3-5 found a configuration that booted.

## 2. How to run an experiment on a tired user
* One image per request, named so it cannot be confused (`-r8`, `-r8-nocrypt`).
* Tell them what the result will prove and how long it takes.
* Ask for five boots, and the count. Give the collector command for the failures.
* Never ask them to compare two phones' behaviours by feel. Give a menu (collect-logs.sh has one): menu / froze on the logo / restarted into the ROM / fastboot / black.
* If a test could write to the phone, say so first; `fastboot boot` writes nothing.

## 3. Bisect plans
When several independent suspects exist and each test costs the user minutes:
1. Write the suspect list and the build that changes **all** of them together (the "kitchen sink").
2. If the kitchen sink is stable, remove half of the suspects per image (binary search) rather than adding them one at a time; each image is a row in the change table (`orangefox-fbe-recovery-port/references/test-ladder-and-safety.md`).
3. If the kitchen sink fails, you learned the suspects are not the cause (or the sink contains a *new* suspect: the r7 recorder). Revert to the last stable image and change fewer things.
4. State the result honestly: "stable with A+B+C changed together; which one mattered is unknown" is a legitimate end state (the reference port ended there).

## 4. The reference port's ladder
rung 0 passed (the ROM's recovery always booted); rung 1 passed about one time in two; rung 2 failed more often; rung 3: the ROM's own kernel binary, byte for byte, did not fix it alone (r7 failed 3 of 3, with other changes);
rungs 4-6 together (stock-like command line, LZMA ramdisk, passive recorder) = r8, which booted and decrypted in its first sessions. Which of the three mattered was not isolated, and r8 later turned out not to be stable either: in one morning four of six recorded boots stopped inside the same 11.5-14.2 s window (`death-window-analysis.md`). A first good session is not a result.

## 5. Stop conditions
* Three consecutive clean sessions of five boots each: call it "very likely stable", write the release notes, stop experimenting.
* The same signature on the control image (rung 0) = not your image: stop changing the tree.
* Evidence that the fault is below the OS (the ROM's own recovery fails the same way): report that to the user and stop; do not keep rebuilding.
