# Safety rules for rescue work

## Contents
1. What is read-only and what writes
2. Never do these
3. Answering "give me a command that deletes ..."
4. Key material: do not touch
5. Before any write: the checklist
6. Flashing packages: read them first

## 1. What is read-only and what writes
| action | writes? |
|---|---|
| `adb pull`, `adb exec-out tar`, `find`, `ls`, `cat`, `sha256sum`, `dd if=PARTITION of=/tmp/...` | no (reads; the output goes to the PC or to RAM) |
| `fastboot boot IMAGE` | nothing is written to the phone |
| mounting `/data` in the recovery (read-write by default) | the filesystem may replay its journal and OrangeFox ran `fsck.f2fs -a` at mount in the reference phone's logs ("Fix the reported corruption"): the filesystem repairs itself; no user file is removed on purpose |
| `android-boot-diagnose.sh` | writes only to `/tmp` (RAM); mounts the ROM's system/vendor read-only under `/tmp` and unmounts them again |
| `fastboot flash recovery IMAGE` | rewrites the recovery partition only |
| sideloading a ROM zip | rewrites system/vendor/product (the `super` partition), boot, dtbo and others; `/data` stays unless the package formats it |
| Format Data, Wipe, `fastboot -w`, `fastboot erase userdata`, "factory reset" | destroys the user's data (with metadata encryption the keys go too) |

## 2. Never do these
* Format Data / Wipe Data / Wipe Internal Storage (OrangeFox: Wipe -> Format Data), or tick `Data` in any wipe dialog: **while `/data` is encrypted and not decrypted it destroys it.**
* `fastboot -w`, `fastboot erase userdata`, `fastboot flash userdata`, or any vendor flashing script without reading it (section 6).
* Flash a test or custom image to `boot` (or `vendor_boot`, `dtbo`, `vbmeta`) of a phone that still has data you need. Test recoveries go with `fastboot boot`; a permanent recovery goes to `recovery` only.
* `rm -r` / `rm -rf` on `/data`, `/sdcard`, `/data/media`, `/metadata`, `/data/misc`, `/data/system`.
* Unlock/relock the bootloader as a "fix": relocking with a non-stock image bricks, and (re)unlocking wipes data on most phones.
* Write anything to the partitions of the other firmware (modem, `persist`, `efs`-type partitions): calibration data (IMEI, Wi-Fi, sensors) lives there and is not in any ROM zip.

## 3. Answering "give me a command that deletes ..."
Users under stress ask for a deletion to get rid of a mismatch (a file count that differs by 2-3, `Android/data`, a folder that "will not copy"). The answer is never a blind command:
1. Say what the difference is first: `compare_listing.py` names each missing file and why; deleting does not make them arrive.
2. Delete on the **PC side** (the copy), not on the phone, when the aim is to make two folders comparable.
3. If something really must be deleted on the phone (a full disk, a corrupt app folder): get the user's explicit statement of the exact path, confirm a verified copy exists, show the command with that exact path (no wildcards, no `*`, no variable that can be empty), and say what is lost.
4. `Android/data` is the private storage of every installed app: removing it deletes app accounts, caches and some documents; it is not needed to rescue photos and it is not a repair.

## 4. Key material: do not touch (see also `recovery-fbe-decryption/references/key-safety.md`)
* `/metadata/vold` (metadata-encryption key blobs) and `/data/unencrypted`, `/data/misc/vold`, `/data/misc/keystore`, `/data/misc/keystore2`, `/data/system_ce`, `/data/system_de`, `/data/misc/gatekeeper`, `/data/system/gatekeeper.*`, `locksettings.db`.
  Deleting or overwriting any of them can make `/data` unreadable forever, even if everything else is healthy. Read them only to collect names and sizes.
* The fake OS/patch level of a custom recovery (99.87.36 / 2099-12-31) makes keymaster "upgrade" key blobs in RAM (log lines "Upgrading key"); the upgraded blob is **not** committed to disk in the reference recovery build. Do not change that behaviour in a build used on a phone with data.

## 5. Before any write: the checklist
* Is a copy of the irreplaceable data on another disk, and was it compared? (`compare_listing.py`: 0 missing, or every missing file explained)
* Is the exact command in front of the user, in words, with what it changes and how to undo it?
* Is there a backup of the thing being overwritten (`dd if=PARTITION of=/tmp/x.img` then `adb pull`) when it is a partition or a small state file (`misc`, a module folder)?
* One change, then a boot test, then a fresh diagnosis. Never two repairs in one go.

## 6. Flashing packages: read them first
A "fastboot ROM" folder usually contains scripts (`flash_all.bat/.sh`, names vary) that end with `fastboot -w` or `erase userdata` / `format` lines, and sometimes a second script that keeps data (the name contains `except` or `keep` ... verify; do not trust the name). Open the script and search for `erase`, `-w`, `format`, `userdata`, `metadata`.
A recovery-installable ROM zip (`updater-script`, `payload.bin`) can contain `format` commands; installing on top of the same ROM ("dirty flash") normally keeps data, but read the ROM's own instructions and the zip's script.
