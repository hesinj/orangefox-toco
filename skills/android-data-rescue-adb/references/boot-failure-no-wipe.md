# Android will not boot: repair without a factory reset

A procedure for choosing the smallest reversible step. It does not promise a cure: some causes (hardware, firmware state) cannot be fixed from the recovery, and then the honest answer is "copy the data, then decide with the user".

## Contents
1. Principles
2. Step A: evidence (read-only)
3. Step B: where does the boot die?
4. Step C: the repair ladder (each step: when, how, undo)
5. Step D: after each step
6. When to stop and say so
7. Case file: the reference phone (open when written)

## 1. Principles
* Data copy first and verified (`SKILL.md` section 2/3). Nothing below needs a wipe; if a step seems to, stop.
* Evidence before action. Every step below is chosen by what the diagnosis shows, not tried "because it often works".
* One change per attempt, a boot test, a fresh diagnosis (`android-diagnose.bat`), compare with the previous one.
* Prefer steps that can be undone by deleting a file or restoring a backup you took.
* The user is usually tired and frightened: short messages, one request at a time, say what is known, what is not, what happens next.

## 2. Step A: evidence (read-only)
Run the diagnosis from the recovery (`android-diagnose.bat`), read it with `diag-bundle-guide.md`. Also ask: what happened just before (an update? a module installed? a full storage? a drop? heat?), what exactly the screen shows (logo forever, animation forever, bootloader screen, recovery screen, restart loop, black), and whether the phone vibrates or the logo ever changes.

## 3. Step B: where does the boot die?
| stage | what the user sees | evidence | typical causes |
|---|---|---|---|
| bootloader | black/no logo, or the bootloader/fastboot screen by itself | `misc` BCB content, vbmeta flags, `persist.sys.boot.reason` | stale BCB command, vbmeta/AVB mismatch after a flash, a deliberate `reboot_on_failure ... bootloader` of init |
| kernel | the manufacturer logo stays; no adb; no boot animation | `13-pstore` (panic, oops, watchdog) or empty; `05b` shows **no** new Android files | boot/dtbo/kernel not matching the vendor firmware, memory corruption, storage/firmware fault; a very long `fsck` on a damaged or full `/data` also keeps the logo (hypothesis: check `10-filesystem`) |
| init / early userspace | logo, then back to the logo, or to the bootloader; no animation | `04` boot reason, `03` last_kmsg of the ROM's recovery, `05b` (did anything get written?), `12` (system vs vendor builds) | a failed early service (`apexd --bootstrap`, `vold`, `servicemanager`), SELinux denial, vendor/system mismatch, a corrupt APEX payload |
| framework | the boot animation loops, or "Android is starting" forever | `06` dropbox (`system_server_*`), tombstones, `08` packages, `07` modules | corrupted package database, a module, a bad app, a full `/data`, a dex/ART cache problem |
Be precise about what is evidence: a boot reason in `/metadata` is the last one **init** recorded; if the failing boots die earlier it is stale.

## 4. Step C: the repair ladder
Do them in order; stop at the first one the evidence does not support.
1. **Full power cycle**: hold Power 15-20 s (or until the phone vibrates and restarts), then a normal start. Costs nothing; clears a stuck charger/boot state. Undo: not needed.
2. **Stale BCB**: only when `02-misc-bcb` shows a `boot-recovery` / `--wipe_data` / `--update_package` command. Back up first (`dd if=/dev/block/bootdevice/by-name/misc of=/tmp/misc.bak bs=4096 count=1`, `adb pull /tmp/misc.bak`), then clear only the defined BCB fields (the first 864 bytes: command 32 + status 32 + recovery 768 + stage 32): `dd if=/dev/zero of=/dev/block/bootdevice/by-name/misc bs=864 count=1`. Undo: `dd` the backup back. Never do this if the command is a data wipe that has not run yet **and** you cannot yet tell why it is there: ask the user whether they requested a reset; clearing it is what *prevents* the wipe, which is what you want, but understand the origin.
3. **Disable root modules** (when `07-root-and-modules` shows Magisk/KernelSU/APatch modules): for each folder `/data/adb/modules/ID` create an empty file `disable` inside it (`touch /data/adb/modules/ID/disable`). Undo: delete the file. Do not delete modules, do not touch `/data/adb/magisk*` data.
4. **Clear the compiled-code caches** (framework-stage failures after an update): OrangeFox Wipe -> Advanced Wipe -> tick **Dalvik / ART Cache** and **Cache** only. **Do not tick Data, Internal Storage, System or Vendor.** The first boot afterwards is slow (recompiling). Undo: not needed (regenerated).
5. **Remove a staged-update state** (init-stage failures right after a pending OTA or APEX update): look at `05-data-layout` (APEX sessions) and `03` (`.UPDATED`, `last_updatefile`). Move (do not delete) the staging folder away: `mv /data/apex/sessions /data/apex/sessions.bak` or the equivalent under `/metadata/apex`, copy the backup to the PC first. Undo: move it back. Use only with evidence of a stuck session.
6. **Dirty flash the same ROM** (when the evidence points at the system/vendor/boot images, or they cannot be shown to be intact): sideload the ROM's recovery-installable zip through the recovery (`adb sideload`), **not** a fastboot ROM script and not with `Format Data`. It rewrites system/vendor/product/boot/dtbo, keeps `/data`. Read the zip's updater-script / the ROM's instructions for any `format` first (`safety.md` section 6). If the same ROM was already dirty-flashed and nothing changed, a third flash proves nothing: the cause is elsewhere (persistent state, hardware, firmware).
7. **Roll back the boot chain** (a flash that preceded the failure): reflash the previous `boot`/`dtbo`/`vendor_boot`/`vbmeta` you saved, or the release's, whole-partition, with `fastboot flash`. Keep the hash of what was on the partition before (`11-boot-partitions`). Only the partitions the evidence implicates.
8. **Boot a diagnostic image with `fastboot boot`** (nothing written): to capture the failing boot's log when no persistent log exists, e.g. the ROM's own kernel and ramdisk with `panic=0` and a passive recorder (`recovery-boot-debugging`). Do it only with the user's consent and after a copy of the data exists.
9. **Stop**: when the ladder is exhausted or the evidence says hardware (UFS read errors, repeated pstore faults in unrelated subsystems, a phone that fails in every ROM and recovery), say so, hand over the verified copy, and let the user decide about reset or service. A factory reset is the user's decision after all of this, never ours.

## 5. Step D: after each step
Boot normally; wait the time a normal first boot takes (a few minutes; the first boot after cache clearing is slower); if it fails, run the diagnosis again and diff `01`, `04`, `05b`, `13` with the previous run. Write the result as a table: step, change, result, what it rules out.

## 6. When to stop and say so
* The evidence of two diagnoses is identical and no step has changed anything.
* The failing stage is the kernel/firmware and the log is empty or shows faults in unrelated subsystems.
* The user is exhausted: stop, summarise in four lines, and offer the next smallest step for later.

## 7. Case file: the reference phone (open when written)
Xiaomi Mi Note 10 Lite (toco, Snapdragon 730G), PixelOS 16.2 build 20260609_1626 on a MIUI V13.0.4.0.SFNMIXM vendor, bootloader unlocked, FBE v2 + metadata encryption + hardware-wrapped keys, no root.
* Symptom: switched off after web browsing, YouTube and Instagram; next morning it stays on the Xiaomi logo.
* Found in the diagnosis: `/metadata/bootstat/persist.sys.boot.reason` was `bootloader,bootstrap-apexd-failed` (until the recovery overwrote it with `reboot,` on 26 October) (the ROM's `apexd.rc` makes a failed `apexd --bootstrap` reboot to the bootloader); `boot`, `dtbo` and `recovery` partitions **sha256-identical to the official PixelOS 20260609_1626 release files** (verified by hashing the partitions on the phone and the downloaded files; the partitions were rewritten by two successful sideloads a few days earlier); storage not full; no module folders; no Android files newer than the last shutdown (the failing boots never wrote to `/data`).
* Deep read tests (two sessions): every file of system, system_ext, vendor, product and odm readable (8,338 files), 36 APEX packages intact, every partition except `userdata` readable raw at normal speed, hashes of the logical partitions stable across reads and sessions, no storage error in the kernel log. The stored system is not the cause.
* **Two failure shapes on different attempts**: one boot reached init and failed at `apexd --bootstrap` (reboot to the bootloader, reason recorded); another hung on the logo with no reason recorded and an empty pstore. A deterministic fault would not change shape.
* Open: why. Hypotheses that fit both shapes and the recovery's random heap corruption: unstable memory or power under load (test: `recovery-boot-debugging/references/ram-stress-test.md`); a TrustZone/firmware state; a driver bug triggered by a coprocessor. Ruled out so far: the boot chain files, the stored system, the APEX packages, `/metadata` state, `misc`, a full disk.
* Steps 2 and 3 of the ladder were not applicable (no BCB command, no modules); steps 4-7 are not supported by the evidence. The data was copied before anything else was tried.
