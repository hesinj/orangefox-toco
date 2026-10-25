# Keeping the user's keys and data safe while decrypting

Decrypting in a recovery touches the most irreplaceable thing on the phone. What the decrypt path does and does not write, and the rules that follow.

## What the decrypt path writes
| action | writes? | notes |
|---|---|---|
| unwrap the metadata key through Keymaster | no | the key blob is read from `/metadata/vold/metadata_encryption/key`; an "upgraded" blob returned by the trusted app is written to `/tmp/keymaster_key_blob/` (RAM). The commit to `/metadata` or `/data` is commented out in TWRP's `system/vold/KeyStorage.cpp` (`BeginKeymasterOp`); verified in the source. Check the same function before claiming it for another branch |
| dm-default-key device + mount of `/data` | the mount itself | read-write by default; the superblock and checkpoint are updated like on every mount |
| `fsck.f2fs -a -c 10000` before the mount (fstab flag `check`) | possibly | a normal pass reads metadata; if the file system was flagged inconsistent (`fsck.f2fs: Info: Fix the reported corruption` appears in the log) it **repairs** it. This is the stock behaviour of the fstab line, not an OrangeFox addition |
| `fscrypt_initialize_systemwide_keys`, `fscrypt_init_user0` | files `/data/unencrypted/ref`, `per_boot_ref` | small reference files ("Wrote system DE key reference to /data/unencrypted/ref") |
| OrangeFox settings and logs | `/data/recovery/Fox`, `/data/media/Fox` | created on first run; they show up as the only files newer than the last Android shutdown |
| backups/flashes the user starts from the menu | yes | only what the user chose |

## Rules
1. **Never Format Data, Wipe Data or Advanced Wipe while `/data` is not decrypted or not yet copied.** They destroy the keys together with the data. Tell the user once, before the first test.
2. Copy the data off first (`android-data-rescue-adb`), then experiment. `adb pull /metadata/vold` additionally keeps a copy of the key blobs; they are useless on any other device but cheap insurance against a damaged `/metadata`.
3. Do not change the lock-screen credential, do not "Fix contexts", do not "Repair file system" from the recovery menu as a diagnostic.
4. Do not flash `userdata`, `metadata`, `super` or `misc` to experiment. `fastboot boot` writes nothing; flashing is for the recovery partition only, and only after clean boots.
5. If the recovery mounts `/data` read-write and the user wants zero writes, `mount -o remount,ro /data` after the decrypt is the lever (not tested on the reference device); the fsck before the mount still ran.
6. The fake OS patch level (2099-12-31) is deliberate: with the real value the trusted app can refuse keys of a newer level. Its side effect (upgrade lines) stays in RAM. Do not "fix" it by committing the upgrade: on the next Android boot the trusted app would see a blob bound to a patch level that the real OS does not have.
7. A wrong password is not an error of the port; a few wrong attempts can trigger Gatekeeper's throttling (the user is then locked out for a while on the phone as well).
8. Everything that deletes on the phone needs the user's explicit, exact scope (see the data-rescue skill).
