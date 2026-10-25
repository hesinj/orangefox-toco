---
name: android-data-rescue-adb
description: Copy the user's files off an Android phone through its recovery with adb (photos, documents, WhatsApp media) without losing or altering anything, check that the copy is complete, and find out why Android no longer boots so that it can be repaired WITHOUT a factory reset. Covers adb pull failures on Windows (names containing a pipe, question mark, asterisk or colon, names ending in a dot, long paths, case collisions, PowerShell corrupting binary pipes), tar streaming, what to skip (Android/data and obb), a read-only diagnosis script for a phone stuck on the logo or bootlooping, and an ordered, reversible repair ladder. Use when someone says things like phone stuck on the logo, bootloop, I need my photos, copy internal storage, adb pull errors, files missing after copy, recover data without wiping, fix Android without factory reset, bootstrap-apexd-failed, or asks for a command that deletes data on the phone.
---

# Getting the data out, and getting the phone back without wiping it

Two jobs that belong together: first make a **verified copy** of what the user cannot replace, then look for the cause of the boot failure with read-only tools and fix it with the smallest reversible step.
Written from a Xiaomi phone whose PixelOS stopped booting overnight and whose encrypted `/data` could be opened only from a custom recovery. Paths are relative to this skill's directory.
Sibling skills: `recovery-fbe-decryption` (opening `/data` in the recovery), `recovery-boot-debugging` (reading kernel panics and pstore), `orangefox-fbe-recovery-port`, `recovery-build-environment`.

## 0. Rules that do not bend (details in `references/safety.md`)
* Never suggest Format Data, Wipe, `fastboot -w`, `fastboot erase userdata`, a flashing script that contains one of them, or `rm -r` on user data. Reading and copying cannot lose anything; deleting can.
* Only `fastboot boot IMAGE` (nothing is written) or flash to `recovery`. Never flash a test image to `boot`.
* Copy first, repair second: a copy takes minutes, every repair attempt is a risk. Verify the copy (`scripts/compare_listing.py`) before trying anything that writes.
* Do not hand out deletion commands to make a file count match. Explain the difference instead (section 3).
* Be honest about writes: mounting `/data` read-write in a recovery replays the f2fs journal and may run `fsck.f2fs -a`; that is the filesystem repairing itself, not a wipe, but it is a write.

## 1. Decide the order
1. The recovery boots and `/data` is decrypted (password typed)? -> copy the data (section 2). Do this before any repair experiment.
2. The recovery cannot decrypt? -> `recovery-fbe-decryption`; do not try to repair Android before you can read `/data`: the evidence is in there.
3. Data copied and verified -> diagnose (section 4).

## 2. Copy the internal storage
```
Windows (Command Prompt, not PowerShell):   scripts\pull-sdcard.bat  E:\phone-backup
macOS / Linux:                              scripts/pull-sdcard.sh   ~/phone-backup
```
What they do: the top-level files in one tar stream (names with spaces or non-Latin letters survive); every top-level folder except `Android` with its own `adb pull` (a folder that fails stops only itself and is retried one level down);
`Android/media` (WhatsApp media and the like). `Android/data` and `Android/obb` are private data of apps and large; they are left out on purpose and cannot be restored by copying anyway.
They write `pull-report.txt` (what worked), `phone-files.txt` (every file the phone has) and compare the counts at the end.
Windows traps (`references/windows-pitfalls.md`): file names Windows cannot hold, `adb pull` aborting at the first folder it cannot create, long paths, PowerShell corrupting binary pipes, `ls` output escaping.

## 3. Check the copy, explain every difference
```
python3 -I scripts/compare_listing.py DEST/phone-files.txt DEST --root /sdcard --windows
python3 -I scripts/compare_listing.py DEST/phone-files.txt DEST/local-files.txt --local-list --local-root DEST   (list made by the .bat; no phone needed)
```
It prints each phone file missing from the copy with the reason: invalid character, trailing dot or space, reserved name (`CON`, `NUL`...), path of 260+ characters, case collision (Windows folders are case-insensitive), or unknown.
A missing file with an explained reason is not damage: the phone still has it. Offer to copy it differently (rename it on the PC side through a tar stream into a Linux/WSL folder, or from macOS/Linux), not to delete anything.

## 4. Android does not boot: diagnose without writing
1. Boot the recovery (`fastboot boot ...`), type the password so that `/data` is open.
2. `scripts\android-diagnose.bat` (Windows) or `adb push scripts/android-boot-diagnose.sh /tmp/ && adb shell sh /tmp/android-boot-diagnose.sh && adb pull /tmp/android-diag.tgz`. It only reads; everything it produces goes to `/tmp` (RAM). Read the archive with `references/diag-bundle-guide.md`.
3. Classify where the boot dies (bootloader / kernel / init / framework) and pick the smallest reversible step from the ladder in `references/boot-failure-no-wipe.md`. One change at a time, a log after each.
4. If the failing boot leaves a kernel panic or no log at all, switch to `recovery-boot-debugging` (pstore, the black-box recorder).

## 5. Scripts
| script | purpose |
|---|---|
| `pull-sdcard.bat DEST` / `pull-sdcard.sh DEST` | read-only copy of `/sdcard` as described above; list files for the comparison |
| `compare_listing.py PHONE_LIST LOCAL ...` | file-by-file reasons for what did not arrive |
| `android-boot-diagnose.sh`, `android-diagnose.bat` | read-only evidence about a phone whose Android does not boot, collected from the recovery (sections 01-summary ... 13-pstore) |

## 6. References
* `references/safety.md`: what may be written, what never, how to answer a request to delete data, key material not to touch.
* `references/windows-pitfalls.md`: why `adb pull` fails on Windows and what the scripts do about it.
* `references/diag-bundle-guide.md`: how to read each section of the diagnosis archive.
* `references/boot-failure-no-wipe.md`: classification, ordered reversible repairs with their undo, the reference phone's case file.

## What was verified and what was not
Verified on the reference phone: the copy scripts' behaviour on Windows (an earlier version of the `.bat`), the diagnosis script's output format, the boot reason and evidence in `boot-failure-no-wipe.md`'s case file. The Unix `pull-sdcard.sh` and `compare_listing.py` were tested only against a stub `adb` and synthetic folders. The repair ladder is a procedure, not a promise: for the reference phone the cause was still open when this skill was written.
