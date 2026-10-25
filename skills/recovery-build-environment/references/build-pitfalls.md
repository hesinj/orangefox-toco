# Build pitfalls (OrangeFox fox_12.1)

## Contents
1. The build command and its environment
2. Variants: full and nocrypt
3. Stale staging directories
4. The device tree is a copy
5. Soong memory and tmpfs
6. Switches the device tree reads
7. Things that look like build bugs but are not

## 1. The build command and its environment
```sh
cd ~/fox_12.1
export LC_ALL=C ALLOW_MISSING_DEPENDENCIES=true FOX_BUILD_DEVICE=<codename>
export OUT_DIR=$PWD/out
source build/envsetup.sh
lunch twrp_<codename>-eng
mka adbd recoveryimage
```
Output: `out/target/product/<codename>/OrangeFox-R12.0-Unofficial-<codename>.{img,zip}` (and `...R12.0_nocrypt-Unofficial...` for the twin).
`scripts/build_fox.sh <codename> [full|nocrypt] [debug]` wraps this and ends with `FOX_BUILD_OK` / `FOX_BUILD_FAILED <step>`.
`FOX_BUILD_DEVICE` and every `FOX_*` switch must be exported **before `lunch`**: the device tree reads them while `lunch` evaluates the makefiles. Changing one afterwards does nothing until `lunch` runs again.
`ALLOW_MISSING_DEPENDENCIES=true` is what lets the minimal TWRP/OrangeFox tree build without the full Android module set.

## 2. Variants: full and nocrypt
Build **both**, every time. The `nocrypt` twin (`FOX_VARIANT=nocrypt`, handled in the device tree's `BoardConfig.mk` / `device.mk`: the template in `orangefox-fbe-recovery-port/assets/device-tree-template` has the `ifneq ($(FOX_VARIANT),nocrypt)` blocks) never starts the TEE daemon, the HALs or keystore2.
That separates "kernel / ramdisk / display / touch broken" from "decryption broken", and it is the control image of every later bug hunt. It is also what the user can fall back to when the full image misbehaves.

## 3. Stale staging directories
OrangeFox builds the ramdisk from `out/target/product/<codename>/recovery/root` and, for the init files of the Qualcomm decryption helpers, from `out/target/product/<codename>/root`. **Neither is cleaned between builds.** Observed on the reference port:
* a file removed from the device tree (`libops.so`, which dragged in the display stack) stayed in two later images;
* the nocrypt variant inherited the decryption `init` files of the previous full build.
`build_fox.sh` removes `root`, `recovery` and `fake_packages` before every build. `verify_image.sh` catches the rest by comparing the ramdisk with the device tree (missing / differing / unexpected files).
A full `out/` clean is only needed when `ninja` itself is confused; deleting the three staging directories is enough for this problem.

## 4. The device tree is a copy
The build reads `<fox>/device/<oem>/<codename>`. The repository is a different directory. `scripts/sync_tree.sh REPO OEM CODENAME` does an `rsync -a --delete` (excluding docs, tools, scripts, kernel recipes, patches, skills, READMEs) and prints the differences that remain, which should be only the excluded items.
Run it before the build and never during one. After editing a file in the repository, forgetting to sync gives an image that does not contain the edit and a `verify_image.sh` that says so (device-tree files differ).

## 5. Soong memory and tmpfs
`soong_build` needs about 11 GB of RAM. Inside a sandbox with a memory cgroup (about 15 GB on the reference machine) **tmpfs counts**: a kernel tree and kernel build directory kept in `/dev/shm` (to save disk) made Soong's analysis get OOM-killed (`Killed`, `Memory cgroup out of memory` in `dmesg`).
Rules: build the kernel on disk; never keep a second tree in `/dev/shm` while Soong runs; if the build is killed, check `dmesg | tail` before blaming the makefiles.

## 6. Switches the device tree reads (reference port; yours may differ)
| switch | effect |
|---|---|
| `FOX_VARIANT=nocrypt` | no decryption stack, twin image |
| `FOX_LZMA_RAMDISK=true` | `BOARD_RAMDISK_USE_LZMA := true`: ramdisk 18 MB instead of 28.6 MB, boot a few seconds slower; check the result with the kernel's own decoder (`recovery-boot-debugging/scripts/unlzma_check`) because the kernel needs `RD_LZMA` and a legacy `.lzma` stream, not xz |
| `FOX_OWN_KERNEL=true` | use the kernel built from source instead of the ROM's binary |
| `FOX_DEBUG_KERNEL=true` | use the KASAN kernel and its command line (`references/kernel-build.md`) |
The names are the device tree's own; the point is to keep every experiment behind a switch so that the release build is the default and an experiment is one `export` away.

## 7. Things that look like build bugs but are not
* An `.img` of exactly the partition size (128 MiB on the reference phone): the build pads it; AVB footer included.
* A WARN from `verify_image.sh` about three `vendor/` files not in the device tree (SELinux contexts, the health HAL manifest fragment): they are produced by the build itself.
* `mounttodecrypt` in `twrp.flags` not mounting the modem partition at start-up: in this OrangeFox source the flag is only used by the password path (`Decrypt_Device()`), not by the metadata decrypt that runs before the GUI. Mount the firmware partition from `init` (`recovery-fbe-decryption`).
* A patch that "does not apply": check `git apply --check` against pristine files first. The startup-hardening patch applies to `bootable/recovery` of branch `fox_12.1` at commit `4f00a3d`; a different base commit may need a rebase.
