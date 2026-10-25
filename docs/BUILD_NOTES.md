# Build notes

How this tree was built, and the problems hit on the way. Paths are the ones used on the
build machine (`/home/user/...`); adjust to taste.

## Machine
Ubuntu 24.04, 4 cores, 15 GB RAM, about 40 GB of disk in total. **That is too little.** A
shallow OrangeFox 12.1 sync is about 19 GB of working tree plus about 8 GB of `.repo`, and the
recovery build adds about 8 GB under `out/`. Plan for 60 GB or more.

## 1. Sync the OrangeFox 12.1 sources
```sh
repo --version                     # https://storage.googleapis.com/git-repo-downloads/repo
git clone https://gitlab.com/OrangeFox/sync.git && cd sync
./orangefox_sync.sh --branch 12.1 --path ~/fox_12.1
```
The script runs `repo sync` against the TWRP minimal manifest, then patches `build/`, `system/`
and `vendor/twrp`, then clones `device/qcom/{common,twrp-common}`, OrangeFox's `bootable/recovery`
and `vendor/recovery`.

On the build machine the disk filled during `repo sync` (the failing project was
`prebuilts/rust`, which alone is 6 GB). Recovery steps that worked, in order:

* delete the `.repo` object stores of projects that were already checked out
  (`scripts/drop_objs.py`; `scripts/inventory.py` lists projects by size and state)
* for `prebuilts/rust`, keep only `linux-x86/1.51.0` (what Soong uses) and delete the
  `darwin-x86` tree and the older Linux versions
* run only the *post-sync half* of `orangefox_sync.sh` afterwards: a copy with the body of
  `get_twrp_minimal_manifest()` replaced by `cd $MANIFEST_DIR` and `--depth=1` added to its
  `git clone` calls. Do not re-run `repo sync` once object stores are gone: it would try to
  re-clone every project.

The resulting tree is no longer a clean `repo` checkout.

## 2. Kernel
Since `r7` the recovery image carries PixelOS's own release kernel by default (`prebuilt/Image-pixelos.gz`, a byte-for-byte
copy of the kernel in PixelOS's `boot-toco_20260609_1626.img`: `unpack_bootimg.py --boot_img boot-toco_20260609_1626.img`,
file `kernel`). `export FOX_OWN_KERNEL=true` before `lunch` selects the kernel built here instead, `FOX_DEBUG_KERNEL=true`
the KASAN one. `tools/verify_image.sh <img> <label> <yes|no> [release|own|debug]` knows all three.

`kernel/build_kernel.sh` builds PixelOS's 4.14 kernel with the clang 12 and gcc 4.9 binutils
already in the OrangeFox tree. Two non-obvious flags were needed:

* `CROSS_COMPILE_COMPAT=arm-linux-androideabi-` - with clang the 32-bit vDSO otherwise links
  with the host `ld` ("cannot represent machine `arm`")
* `OBJCOPY=llvm-objcopy` - the 64-bit `objcopy` cannot process the 32-bit vDSO ELF

Outputs used: `arch/arm64/boot/Image.gz`; `xiaomi-sdmmagpie.dtb` as `prebuilt/dtb`;
`toco-sdmmagpie-overlay.dtbo` packed with AOSP's `mkdtboimg.py create --page_size=4096`
into `prebuilt/dtbo.img`.

## 3. Recovery
```sh
cd ~/fox_12.1
export LC_ALL=C ALLOW_MISSING_DEPENDENCIES=true FOX_BUILD_DEVICE=toco
source build/envsetup.sh && lunch twrp_toco-eng && mka adbd recoveryimage
```
(`scripts/build_fox.sh` wraps this.) Output: `out/target/product/toco/OrangeFox-R12.0-Unofficial-toco.{img,zip}`.

### Things that broke the build, and the fixes
* **Out of space** (`ld.lld: ... No space left on device`). Beyond the steps above, what freed
  space safely: the macOS/Windows host directories under `prebuilts/`, and truncating the large
  data files under `prebuilts/vndk` and `prebuilts/sdk/{29,30,31,32}` to zero bytes.
  `ninja -t inputs adbd recoveryimage` showed no build input comes from those trees. Truncating
  (not deleting) keeps Soong's file-existence checks happy.
* **Do not delete `prebuilts/clang/host/linux-x86/clang-r416183b`**, even though the platform
  itself uses `clang-r416183b1`. The prebuilt `rustc` has a RUNPATH into
  `.../clang-r416183b/lib64` (for `libc++.so.1`), and bindgen runs
  `clang-r416183b/bin/clang`. Neither shows up in ninja's input list. If it is gone,
  `ln -s clang-r416183b1 clang-r416183b` fixes both.

## 4. Static checks used
```sh
python3 system/tools/mkbootimg/unpack_bootimg.py --boot_img OrangeFox-...img --out /tmp/u
python3 external/avb/avbtool.py info_image --image OrangeFox-...img
mkdir /tmp/rd && cd /tmp/rd && gzip -dc /tmp/u/ramdisk | cpio -idm
python3 -I tools/verify_ramdisk.py /tmp/rd
```
`tools/verify_ramdisk.py` resolves every `DT_NEEDED` entry of the decrypt binaries, plus the
libraries `qseecomd` loads with `dlopen`, against the ramdisk. Its first run caught two real
gaps (`libtime_genoff.so` missing; `libops.so` pulling in the display stack).

## What was not verified
Nothing has been run on a device: boot, display, touch, USB, and above all decryption of
PixelOS (Android 16) userdata are untested.

## Iteration notes (what the first report from a device taught)

* **Stale files in the output directory.** OrangeFox builds the ramdisk from `out/target/product/toco/recovery/root`
  and, for the init files of the Qualcomm decryption helpers, from `out/target/product/toco/root`. Neither is
  cleaned between builds. A file removed from the device tree (`libops.so`) therefore stayed in `r1` and `r2`, and the
  `-nocrypt` variant inherited the decryption `init` files of the previous full build. Before every build:
  `rm -rf out/target/product/toco/{root,recovery,fake_packages}`. `tools/verify_image.sh` compares the
  ramdisk with the device tree, so this is caught.
* **`mounttodecrypt` does not help at start-up.** In this OrangeFox source the flag is only used by
  `Decrypt_Device()` (typing a password), not by the metadata decrypt that runs before the GUI. The `modem`
  partition is therefore mounted from `init` (`/vendor/firmware_mnt`, read-only).
* **The start-up decrypt had no time limit.** `fscrypt_mount_metadata_encrypted()` -> `Keymaster()` ->
  keystore2 -> `IKeymasterDevice::getService()` waits for ever for the Keymaster HAL. The patch runs
  it in a worker thread, logs the state of the chain and gives up after 90 s.
* **`qseecomd`** was disassembled (`llvm-objdump -d`): RPMB and SSD initialisation are mandatory and run
  as root before the privilege drop; the other eight listeners are optional.
* Builds use `build_fox.sh [variant]`; `FOX_VARIANT=nocrypt` selects the variant without decryption.


## Hunting the kernel memory corruption (r4)

* **Evidence.** `pstore` (`console-ramoops-0`, read with `toco-logs.bat` after a forced restart that kept the phone in
  fastboot) held the oops of a frozen boot: `__kmalloc_track_caller` found a garbage free-list pointer in `kmalloc-512`.
  Details and the reasoning are in `docs/TROUBLESHOOTING.md`.
* **Debug kernel.** `kernel/build_kernel.sh` with `FRAGMENT=debug.fragment` after applying `kernel/debug-kernel.patch` to the
  kernel checkout. The fragment turns on KASAN (generic, outline), `SLUB_DEBUG`, `DEBUG_LIST`, `BUG_ON_DATA_CORRUPTION` and a 2 MB log
  buffer; the command line adds `slub_debug=FZPU kasan_multi_shot nokaslr panic=0`. The patch
  * makes `KASAN_STACK_ENABLE` default to off (this tree has no `CC_IS_CLANG`, so the symbol is invisible and
    cannot be switched off from the config),
  * drops global-variable redzones (`asan-globals=0`),
  * adds `KASAN_ONLY` to `scripts/Makefile.lib`, a list of directory patterns; everything else is built without
    instrumentation,
  * stops the Qualcomm WLAN driver from referencing `__qdf_bug()` (it is only defined in the driver's debug
    build, and `CONFIG_SLUB_DEBUG=y` made the default profile ask for it: link error).
* **Why not instrument everything.** The first debug kernel was 87 MB (`Image`) + 20 MB `bss`, against 42 MB + 7 MB for the release kernel.
  The kernel is placed at `0x80080000` and the first firmware-reserved region (`hyp_region`) starts at `0x85700000`,
  so the whole footprint has to stay below about 86 MiB. The release kernel needs 48 MB, the instrumented-everywhere one 107 MB.
* **Build memory.** The sandbox runs builds in a memory cgroup of about 15 GB that also counts `tmpfs`. `soong_build` needs about
  11 GB of it. A kernel tree and build directory kept in `/dev/shm` (to save disk) made Soong's analysis get OOM-killed
  (`Killed`, `Memory cgroup out of memory` in `dmesg`). Do not build the kernel in `/dev/shm` and the recovery at the same time;
  remove the kernel tree from `/dev/shm` before building images.
* `scripts/build_fox.sh [full|nocrypt] [debug]` cleans the staging directories and selects `prebuilt-debug/` for `debug`.
