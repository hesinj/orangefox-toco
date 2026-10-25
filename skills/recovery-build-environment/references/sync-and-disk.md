# Syncing the OrangeFox 12.1 sources on a small disk

## Contents
1. Numbers to plan with
2. The sync
3. When the disk fills during the sync
4. When the disk fills during the build
5. What never to delete
6. After pruning: what no longer works

## 1. Numbers to plan with (measured)
| item | size |
|---|---|
| shallow `fox_12.1` working tree | about 19 GB |
| `.repo` object stores | about 8 GB |
| `out/` after one recovery build | about 8 GB more |
| `prebuilts/rust` alone | about 6 GB |
| `soong_build` analysis | about 11 GB of RAM |
Recommended: 60 GB free disk, 16 GB RAM, 4 cores or more. Check `df -h` before and during the sync; a sandbox may report "Avail 0" while "Used" is low because its writable allowance is a fixed quota, not the partition size.

## 2. The sync
```sh
repo --version                                   # https://storage.googleapis.com/git-repo-downloads/repo
git clone https://gitlab.com/OrangeFox/sync.git && cd sync
./orangefox_sync.sh --branch 12.1 --path ~/fox_12.1
```
The script runs `repo sync` against the TWRP minimal manifest, patches `build/`, `system/` and `vendor/twrp`, then clones `device/qcom/common`, `device/qcom/twrp-common`, OrangeFox's `bootable/recovery` and `vendor/recovery`.
Keep the log (`> sync.log 2>&1`) and `repo manifest -o effective_manifest.xml` after the sync: `scripts/inventory.py` and `scripts/drop_objs.py` read it.

## 3. When the disk fills during the sync
The failing project on the reference machine was `prebuilts/rust`. Steps that worked, in this order:
1. **Free the object stores of projects that are already checked out**: `python3 -I scripts/inventory.py <tree> effective_manifest.xml` prints the 30 biggest projects with their working-tree and object-store sizes, which projects have no working tree yet, and the totals; `python3 -I scripts/drop_objs.py <tree> effective_manifest.xml prebuilts/` deletes `.repo/projects/<path>.git` and `.repo/project-objects/<name>.git` of every project under that path prefix **whose working tree already exists** (it skips `prebuilts/rust`, which is the one still being fetched). Run it with a prefix that matches what you can spare (`prebuilts/`, then `external/`, ...), re-run `inventory.py` to see what is left. After this, git history is gone for those projects: their working trees are plain files.
2. **`prebuilts/rust`**: keep only `linux-x86/1.51.0` (what Soong uses); delete the `darwin-x86` tree and the older Linux versions.
3. **Do not run `repo sync` again** after object stores are gone: it tries to re-clone every project. Run only the *post-sync half* of `orangefox_sync.sh`: a copy of the script with the body of `get_twrp_minimal_manifest()` replaced by `cd $MANIFEST_DIR` and `--depth=1` added to its `git clone` calls.
The result is a working tree that is no longer a clean `repo` checkout. That is acceptable for building one recovery; do not expect `repo status`, `repo sync` or branch switching to work on it. Re-sync into a fresh directory for another branch.

## 4. When the disk fills during the build
Symptom: `ld.lld: ... No space left on device`, or ninja stops in the middle of linking. What freed space safely (all verified by `ninja -t inputs adbd recoveryimage`, which lists the inputs of the targets):
* the macOS and Windows host directories under `prebuilts/` (AOSP names them `darwin-x86` and `windows-x86`; a Linux build reads none of them);
* the large data files under `prebuilts/vndk` and `prebuilts/sdk/{29,30,31,32}`: **truncate them to zero bytes, do not delete them**. `ninja -t inputs` showed no build input comes from those trees, but Soong's analysis checks that the files exist, and a truncated file satisfies it.
Check before trimming anything else: `ninja -t inputs adbd recoveryimage > inputs.txt` (after one successful analysis) and grep the directory you want to remove. Anything not in that list *and* not referenced by a prebuilt tool's RUNPATH is a candidate; the second condition is the one ninja cannot tell you (section 5).

## 5. What never to delete
* `prebuilts/clang/host/linux-x86/clang-r416183b`, **even though the platform itself uses `clang-r416183b1`**. The prebuilt `rustc` has a RUNPATH into `.../clang-r416183b/lib64` (for `libc++.so.1`), and bindgen runs `clang-r416183b/bin/clang`. Neither shows up in ninja's input list. If it is gone: `ln -s clang-r416183b1 clang-r416183b` fixes both.
* The toolchains `build_kernel.sh` uses (`prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9`, `.../arm/arm-linux-androideabi-4.9`): a kernel build needs them.
* Do not prune `out/` and sources in the same step you are debugging: after a failed build, change one thing and rebuild, so that the next failure has one possible cause.

## 6. After pruning: what no longer works
* `repo sync`, `repo status`, `repo forall`, branch switches.
* A later wish to rebuild a different Android branch in the same directory.
Record in the build notes that the tree was pruned and which directories were truncated, so that a later "why is this file empty" has an answer.
