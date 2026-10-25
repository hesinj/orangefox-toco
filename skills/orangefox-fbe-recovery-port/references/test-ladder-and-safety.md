# Test ladder, data safety and how to work with the person holding the phone

The person testing is usually the phone's owner, not an engineer, and every test costs them a cable, a button sequence and a
report. These rules came from a port where the owner tested eight image revisions and was exhausted by failures that a better
protocol would have caught earlier.

## Contents
1. Data-safety rules
2. Boot methods and what they change
3. The ladder
4. Asking for a test, asking for logs
5. What the phone's reaction means
6. Counting stability
7. After a freeze: keep the evidence
8. Change table template

## 1. Data-safety rules
* `fastboot boot <img>` writes nothing to the phone. It is the only way to run an untested image. Flashing the recovery partition
  comes last and only for `recovery` (never `boot`, `vbmeta`, `userdata`, `metadata`, `super`).
* While `/data` is not decrypted, **Format Data, Wipe Data, Advanced Wipe and `mkfs`/`fastboot erase` destroy the user's data
  for good.** Tell the user once, plainly, before the first test: do not touch the wipe or format entries.
* Recovery menus and OrangeFox's "Fix Contexts", "Repair or change file system" are not diagnostics. Avoid them.
* The decrypt code in the OrangeFox/TWRP vold copy keeps upgraded key blobs in RAM (`/tmp`): the commit to `/metadata`/`/data` is
  commented out in `system/vold/KeyStorage.cpp` (verified in the source: `BeginKeymasterOp` writes the upgraded blob to
  `/tmp/keymaster_key_blob/` and never commits it). Check the same lines in any other branch before claiming it.
* `fsck.f2fs -a` runs when `/data` is mounted (the fstab flag `check`): normally a read-only pass, but it may repair a filesystem
  that was not shut down cleanly. It is part of the stock behaviour of every mount of that fstab line.
* Copy the data off **first** (`android-data-rescue-adb`); then experiment. A tiny extra precaution that costs nothing:
  `adb pull /metadata/vold` keeps a copy of the metadata key blobs (they are bound to the device's TEE, useless elsewhere).
* Never give a deletion command whose scope is wider than what the user said. Ask for the exact path; offer a dry run (`ls`/`find` first).
* A locked bootloader cannot boot a custom recovery. Do not suggest unlocking: that wipes the data and is the user's decision.

## 2. Boot methods and what they change
| method | writes to the phone | notes |
|---|---|---|
| `fastboot boot img` | nothing | some bootloaders refuse it; a reboot afterwards returns to the installed OS |
| key combination into a flashed recovery | nothing at boot, but the image had to be flashed first | no live fastboot session before the kernel starts: a different starting condition than `fastboot boot` |
| `fastboot flash recovery img` | the recovery partition | after several clean `fastboot boot` runs only; keep the previous recovery image to flash back |
On the reference device `fastboot boot` of the full image worked in the end; the flashed-recovery route was never needed.

## 3. The ladder (stop at the first rung that fails and fix it before going on)
0. **Control.** The ROM's own recovery image (or any known-good image) boots with `fastboot boot` several times. Proves cable, driver, bootloader, and
   that the bad news is not the phone. On the reference device the ROM's own recovery always booted.
1. **`nocrypt` build.** Boots? Touch works? `adb devices` lists it as `recovery`? Run the log collector once. If this fails, the cause is the kernel,
   the ramdisk, the display/touch/USB setup or a hardware-level instability: go to `recovery-boot-debugging`, not to decryption.
2. **`full` build.** Same checks; then read `recovery.log` (`recovery-fbe-decryption/scripts/analyze_recovery_log.py`). Expected order of markers: `prepdecrypt::Script
   complete`, `Retrieving key from keymaster`, `Successfully decrypted metadata encrypted data partition`, `fscrypt_init_user0`, `fox.decrypt.state=done`.
3. **Password.** The OrangeFox password page unlocks the user's credential-encrypted storage. A wrong password is not an error of the port;
   the same secret as the lock screen is needed.
4. **Copy data off** (`android-data-rescue-adb`).
5. **Stability.** Five boots in a row (section 6).
6. **Flash** (optional): only if the user wants a permanent recovery.

## 4. Asking for a test and for logs
A good request has: what to do (numbered, short), what the result shows, and one command that returns everything needed.
* Template: "1) power the phone off, hold Volume-Down + Power to reach fastboot. 2) run `fastboot boot <image>`. 3) wait for the menu or password
  screen, or two minutes if it does not come. 4) run `recovery-logs` (the collector script) and send the zip. Tell me what the screen did (menu, logo
  forever, restarted into the ROM, black)."
* The collector scripts in `recovery-boot-debugging/scripts/` are read-only on the phone and include a "what did the phone do" question on Linux/macOS.
* When the phone froze: the evidence is in RAM (pstore) and is lost if the ROM boots first. Give the "after a freeze" steps (section 7) *before* the
  user restarts the phone, not after.
* Ask for one thing at a time. Do not ask the user to compare, retry or decide between options they cannot judge.
* Say how long each test takes and when it is safe to stop. Say what the test proves, in one sentence, so a failure is not a mystery.
* Translate everything into the user's language; keep command lines verbatim.

## 5. What the phone's reaction means
| phone | meaning |
|---|---|
| menu, internal storage visible | decryption works |
| menu with a password prompt | the metadata layer opened; the password unlocks the user keys |
| menu after ~90 s with "Decryption services did not answer in time" | the recovery is fine, a link of the chain is missing: logs (`failure-signatures.md`) |
| logo for more than 3 minutes, adb answers | the decrypt step is stuck (older builds without the 90 s limit), or the GUI failed: pull `/tmp/recovery.log` |
| frozen logo, adb silent, buttons dead (builds with `panic=0`) | a kernel panic: hold Power until it restarts, keep holding Volume-Down to land in fastboot, then section 7 |
| restarts into the installed ROM within seconds | something reset the phone: a panic on a build without `panic=0`, or a watchdog |
| fastboot screen | init hit a fatal error and rebooted to the bootloader |
| black screen, adb works | display driver or brightness node problem (`TW_BRIGHTNESS_PATH`, panel DT) |

## 6. Counting stability
One boot proves nothing; the reference recovery came up one time in two for weeks. Ask for **five boots in a row** and the count of those that reached
the menu. Zero failures in five is "very likely stable", not "proven"; say it that way. A boot count per image belongs in the change table.

## 7. After a freeze: keep the evidence
Hold Power until the phone restarts and **keep Volume-Down held** so it lands in fastboot (booting the ROM first can overwrite pstore, and some
bootloaders clear it on a power cycle). `fastboot boot` the same image, and when it is up run the collector: `pstore.txt` holds the console of the
frozen boot, `fox-bb/` holds the recorder files of the last boots (`recovery-boot-debugging/references/pstore-and-panic-logs.md`).

## 8. Change table template (keep one per release, put it in the release notes)
| image | base | kernel | ramdisk | cmdline | recorder | other | result (boots out of N) |
|---|---|---|---|---|---|---|---|
| r1 | - | own build | gzip 28 MB | stock + panic=0 | none | - | logo, adb up |
Fill one row per image **before** sending it. A row that differs from the previous one in more than one column needs a reason.
