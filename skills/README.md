# Skills: an OrangeFox recovery that can decrypt `/data`

Five Claude skills written from one real port: OrangeFox for the Xiaomi Mi Note 10 Lite (Snapdragon 730G) reading the encrypted userdata of PixelOS / Android 16
(file-based encryption v2, metadata encryption, hardware-wrapped keys). If a similar phone ever shows 0 MB in its recovery, asks for a password that is not accepted, or sits on a logo,
these skills let Claude get to a working recovery much faster, and to the user's files without a factory reset.
Persian summary: [README.fa.md](README.fa.md).

| skill | use it when |
|---|---|
| [`orangefox-fbe-recovery-port`](orangefox-fbe-recovery-port/SKILL.md) | **start here**: port or build OrangeFox/TWRP for a phone and make it read an encrypted `/data` (workflow, intake checklist, device-tree generator, test ladder) |
| [`recovery-fbe-decryption`](recovery-fbe-decryption/SKILL.md) | the recovery must open `/data`: fstab flag mapping, what the ramdisk needs (Keymaster/KeyMint, Gatekeeper, `qseecomd`, VINTF manifests), log analyzer, failure signatures, key safety |
| [`recovery-boot-debugging`](recovery-boot-debugging/SKILL.md) | a boot freezes, restarts or loses adb: pstore, the passive black-box recorder, reading an arm64 oops, SLUB heap corruption, honest kernel/ramdisk comparisons |
| [`recovery-build-environment`](recovery-build-environment/SKILL.md) | sync the sources on a small disk, build `full` + `nocrypt` images, kernel builds, static image checks, release notes |
| [`android-data-rescue-adb`](android-data-rescue-adb/SKILL.md) | copy the user's files off through the recovery (Windows pitfalls), and diagnose an Android that will not boot without wiping it |

## Install
* **Claude Code**: copy the five folders (and `_shared/`, `SHARED.txt`, `sync_shared.sh` if you want to maintain them) into `~/.claude/skills/` (all projects) or `<project>/.claude/skills/`. The skills refer to each other by name.
* **Claude.ai / desktop**: upload the five `.skill` packages from `dist/` (one per skill) in Settings, Capabilities, Skills. Keep all five installed: they cross-reference each other.
* Needs: `python3` (3.8+), `bash`, `adb`/`fastboot` for the phone-side scripts. The decryption scripts run on a PC; the `.sh` scripts that start with `#!/system/bin/sh` run in the recovery.

## Quick start (say this to Claude)
* "I want OrangeFox for my phone (model, ROM). Its recovery shows 0 MB / won't take my password. Use the skills to plan the port." -> `orangefox-fbe-recovery-port`
* "Here is my recovery.log, why does decryption fail?" -> `recovery-fbe-decryption` (`scripts/analyze_recovery_log.py`)
* "My custom recovery freezes about every second boot." -> `recovery-boot-debugging`
* "repo sync ran out of space / verify this recovery image before I flash it." -> `recovery-build-environment`
* "My phone is stuck on the logo, I need my photos and don't want a factory reset." -> `android-data-rescue-adb`

## What is verified
Everything was done on one device (SM6150, A-only with a recovery partition, dynamic partitions, boot header v2, Qualcomm Keymaster 4.1 HIDL HAL, OrangeFox `fox_12.1`): boot, display, touch, adb, decryption of PixelOS Android 16 userdata including the lock-screen password, and `adb pull` of the internal storage. One stable session was reported; **stability across many boots was not proven**, and the root cause of the kernel heap corruption seen on the way was never found (`recovery-boot-debugging/references/toco-heap-corruption-evidence.md`).
Other SoCs (MediaTek, Exynos, Tensor), A/B and `vendor_boot` devices, AIDL KeyMint vendors are reasoned, not tested, and are marked unverified where they appear. The Unix `pull-sdcard.sh` and the build scripts were tested against stubs and on the reference build tree only.
The skills never suggest Format Data, Wipe or a factory reset, and say so to the user.

## Layout
```
_shared/                    single source of the scripts that several skills carry (SHARED.txt lists the copies; ./sync_shared.sh keeps them identical)
<skill>/SKILL.md            front matter + workflow (under 500 lines); references/ scripts/ assets/ evals/ next to it
tests/smoke_shared.sh       a few dozen checks that need no phone: syntax, shared copies, front matter, and each script on small synthetic input
```
Run `bash tests/smoke_shared.sh` after any change. `evals/` of every skill holds test prompts with graders in the layout `claude plugin eval` reads (`claude plugin eval . --allow-tools Write,Edit,Bash` from a skill folder; it makes real, billed model runs).

## Licences and provenance
The scripts and documents here are original work of this repository; no licence has been chosen for them yet (the repository has no licence file), so the owner has to decide before others reuse them. Provenance of everything else is in `../NOTICE.md`. `recovery-boot-debugging/scripts/unlzma_check/unlzma_kernel.c` is the Linux kernel's `lib/decompress_unlzma.c` unmodified (LGPL-2.1-or-later, header kept). `assets/0001-startup-hardening.patch` is a patch to OrangeFox's `bootable/recovery` (GPL-3.0-or-later like the files it touches). Vendor binaries are not included; `collect_decrypt_blobs.py` copies them from the user's own ROM.
