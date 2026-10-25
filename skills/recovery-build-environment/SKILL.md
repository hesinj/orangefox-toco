---
name: recovery-build-environment
description: Sync the OrangeFox fox_12.1 sources, build a recovery image (full and nocrypt twin), build or reuse a kernel with the toolchains inside the tree, and check the result statically before anybody boots it. Covers sizing the build machine, recovering from a full disk during repo sync or the build, staging directories that leak stale files into the next image, the second clang directory that must never be deleted, Soong out-of-memory kills, syncing the device tree into the build tree, collecting a release with sha256 sums, and writing release notes that state what was and was not verified. Use when someone says build OrangeFox, lunch, mka recoveryimage, repo sync ran out of space, ld.lld no space left on device, soong killed, verify the recovery image, check the ramdisk, build a debug or own kernel, or prepare a release for a phone port.
---

# Building, checking and shipping a recovery image

The mechanics around an OrangeFox (`fox_12.1`, Android 12 build system) port: a machine that is big enough, a source tree that survives, builds that do not leak yesterday's files,
static checks that replace a failed boot test, and a release that tells the truth. Everything here was done on one port (Xiaomi Mi Note 10 Lite, Snapdragon 730G) on a machine that was too small, which is where most of the lessons come from.
Paths are relative to this skill's directory. Sibling skills: `orangefox-fbe-recovery-port` (the whole workflow, device tree), `recovery-fbe-decryption` (what the ramdisk must contain), `recovery-boot-debugging` (when a boot fails), `android-data-rescue-adb` (copying the data).

## 1. Size the machine before the first command
Plan for **60 GB of free disk and 16 GB of RAM** (verified numbers: the shallow `fox_12.1` working tree is about 19 GB, `.repo` about 8 GB, the recovery build adds about 8 GB under `out/`; `soong_build` needs about 11 GB of RAM).
The reference machine had 40 GB and 15 GB: the disk filled during `repo sync` and again during the build, and the recovery steps (`references/sync-and-disk.md`) cost a day. If the machine cannot be enlarged, read that file before syncing, not after.

## 2. Workflow
1. **Sync** the tree (`references/sync-and-disk.md`): `orangefox_sync.sh --branch 12.1 --path ~/fox_12.1`. Watch the disk while it runs. Never run it twice over a tree whose object stores were pruned.
2. **Put the device tree in place**: `scripts/sync_tree.sh REPO OEM DEVICE` copies the repository's tree into `<fox>/device/<oem>/<device>`. The build uses that **copy**: edits in the repository do nothing until synced, and syncing during a build corrupts it.
3. **Build both variants**: `scripts/build_fox.sh DEVICE full` and `... nocrypt` (`FOX_VARIANT=nocrypt`, no decryption stack). The script clears the staging directories first (`references/build-pitfalls.md`: stale files) and prints `FOX_BUILD_OK` or `FOX_BUILD_FAILED <step>`.
4. **Verify statically**: `scripts/verify_image.sh IMG LABEL yes|no` (header, size, AVB footer, kernel/dtb/dtbo against the tree, ramdisk against the device tree, VINTF manifest, decryption stack present or absent, library closure via `scripts/verify_ramdisk.py`). Fix every FAIL before anyone boots the image (`references/image-checks.md`).
5. **Release**: `scripts/run_release.sh DEVICE TAG` builds both variants and collects `<name>-TAG.img/.zip` with `SHA256SUMS`; write the notes with `references/shipping.md` (verified / not verified, provenance, the exact test the user should run).
6. **Kernel** only if the ROM's own kernel binary cannot be used (`references/kernel-build.md`): `scripts/build_kernel.sh`, plus the KASAN fragment and patch for hunting memory corruption.

## 3. The lessons that cost the most (all verified on the reference build)
| symptom / trap | cause | do this |
|---|---|---|
| a file removed from the device tree is still in the new image; the nocrypt image carries the decrypt `init` files of the last full build | `out/target/product/DEVICE/{root,recovery,fake_packages}` are not cleaned between builds | `build_fox.sh` deletes them before every build; `verify_image.sh` compares the ramdisk with the tree |
| `ld.lld: ... No space left on device`, `repo sync` dies at `prebuilts/rust` | too small a disk | `references/sync-and-disk.md` (prune object stores, trim prebuilts, which directories are safe to truncate) |
| rustc or bindgen fail after cleaning `prebuilts/clang` | the prebuilt rustc has a RUNPATH into `clang-r416183b/lib64` and bindgen runs `clang-r416183b/bin/clang`; neither is in ninja's input list | never delete `clang-r416183b`; if it is gone: `ln -s clang-r416183b1 clang-r416183b` |
| Soong analysis `Killed`, `Memory cgroup out of memory` in dmesg | a kernel tree or build directory in `/dev/shm`: tmpfs counts against the sandbox's cgroup | build kernels on disk, never in `/dev/shm` next to a soong run |
| edits to the repository have no effect on the image | the build reads a copy of the device tree | `sync_tree.sh`, then rebuild |
| kernel link error "cannot represent machine arm" / objcopy fails on the vDSO | clang build with the 64-bit host `ld` / `objcopy` for the 32-bit vDSO | `CROSS_COMPILE_COMPAT=arm-linux-androideabi-` and `OBJCOPY=llvm-objcopy` (in `build_kernel.sh`) |
| image "built fine" but nobody knows what is in it | no static check | `verify_image.sh`; "it built" is not evidence |

## 4. Scripts
| script | purpose |
|---|---|
| `build_fox.sh DEVICE [full\|nocrypt] [debug]` | clean staging, `lunch twrp_DEVICE-eng`, `mka adbd recoveryimage`; env `FOX`, plus the device tree's own `FOX_*` switches |
| `sync_tree.sh REPO OEM DEVICE` | rsync the repository's device tree into the build tree, report what differs |
| `run_release.sh DEVICE TAG [OUTDIR]` | build full + nocrypt, copy as `NAME-TAG.img/.zip`, write `SHA256SUMS` |
| `verify_image.sh IMG LABEL yes\|no` | the static checks; exit status 1 on any FAIL; options by environment (see its header) |
| `verify_ramdisk.py DIR ...` | ELF-level library closure of the decryption services (copy of the shared script; options in `recovery-fbe-decryption`) |
| `inventory.py`, `drop_objs.py` | list projects of a manifest by size/state; free the object stores of checked-out projects |
| `build_kernel.sh`, `debug.fragment` | kernel build template with the in-tree toolchains; KASAN/SLUB/page-poisoning fragment |

## 5. References
* `references/sync-and-disk.md`: sync, disk planning, what to delete and what never to delete.
* `references/build-pitfalls.md`: build environment variables, staging, variants, the device-tree copy, Soong memory.
* `references/kernel-build.md`: reuse vs rebuild, toolchain flags, outputs (Image.gz, dtb, dtbo), debug kernel and its size limit.
* `references/image-checks.md`: every check of `verify_image.sh`, manual unpack/AVB commands, reading a WARN.
* `references/shipping.md`: release layout, notes template, provenance and licences, what is the user's step.

## What was not verified
Only one SoC family and one device tree were built (Qualcomm SM6150, `fox_12.1`). Other OrangeFox branches (fox_14.1 and later), MediaTek and Exynos build flags, and A/B vs non-A/B differences are not covered; treat statements about them elsewhere in these skills as unverified.
