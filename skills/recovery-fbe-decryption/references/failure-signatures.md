# Failure signatures: symptom -> cause -> fix

Seen = observed in logs from the reference phone. Read-from-source = derived from the init files, the binaries or the source, never seen failing.
Run `scripts/analyze_recovery_log.py <log dir>` first: it matches most of these automatically.

## Contents
1. Triage order
2. The table
3. Reading the "Decrypt: waiting" line
4. When the log is silent
5. Success markers

## 1. Triage order
1. Is it a kernel panic or a hang before userspace (log stops at a kernel line, adb dead, no `recovery.log`)? -> `recovery-boot-debugging`, not this file.
2. Did the decrypt start (`fscrypt_mount_metadata_encrypted` in the log)? No -> section 4.
3. Which `init.svc.*` is not `running` in the last `Decrypt: waiting` line? That is the link to fix.
4. Everything running and still no `Successfully decrypted`? -> keystore2 / Keymaster answer path: rows 6-9.

## 2. The table
| # | symptom (exact strings) | cause | fix | status |
|---|---|---|---|---|
| 1 | log ends at `prepdecrypt::Script complete. Device ready for decryption.`; UI never appears; adb answers | `fscrypt_mount_metadata_encrypted()` waits, unbounded, for keystore2 -> Keymaster HAL -> TEE | OrangeFox patch (bounded thread + state lines); then use the rows below | seen |
| 2 | logcat `F keystore2: Check failed: serviceManager.get() Failed to get ServiceManager`; `init.svc.keystore2=restarting`; hwservicemanager `Cannot read /system/etc/vintf/manifest.xml`, `getTransport: Cannot find entry android.hidl.manager@1.2::IServiceManager/default` | no framework VINTF manifest in the ramdisk | add `system/etc/vintf/manifest.xml` (framework, declares `android.hidl.manager@1.2`) | seen |
| 3 | Keymaster HAL starts then exits, or logs it cannot start its trusted app | firmware partition not mounted at `/vendor/firmware_mnt` (trusted app not found) | mount the modem partition ro from init; check `ls /vendor/firmware_mnt/image` in the diag block | seen (fix verified, failure mode inferred) |
| 4 | `QSEECOMD ... RPMB_INIT failed` or `SSD_INIT failed`; `init.svc.qseecomd=stopped` | RPMB/SSD init failed: `/dev/sg*` or `ssd` partition not accessible, ueventd rule missing | ueventd permissions, by-name `ssd`, UFS RPMB LUN | read-from-source (disassembly), not seen failing |
| 5 | `vendor.sys.listeners.registered` empty, qseecomd `running` | qseecomd stuck inside a listener start | run the services by hand (`recovery-boot-debugging/scripts/probe_services.sh` in a nocrypt image) | seen once (a probe froze the phone right after `rpmb_init`, see the debugging skill) |
| 6 | `init.svc.keymaster-4-1-qti` not running while qseecomd is | library missing or the service name does not match `keymaster_ver` | `verify_ramdisk.py`; check the `keymaster_ver` line and that the binary name equals the `service` stanza path | read-from-source |
| 7 | all services running, still no result | the TA does not answer or keystore2 never reached the HAL | `fox-diag` blocks: keystore2 / km_compat lines, kernel `qseecom` lines | seen (row 2 was the cause) |
| 8 | `Unable to decrypt metadata encryption` / `Failed to mount data after metadata decrypt` | the metadata key was unwrapped but the mount failed: kernel lacks f2fs options or inline crypto; flags differ from the ROM's | compare the data line with the ROM fstab; `kernel_marker_check.sh` | read-from-source |
| 9 | `Metadata FBE decrypt support not present in this build` | built without `TW_INCLUDE_FBE_METADATA_DECRYPT` | set it | read-from-source |
| 10 | metadata decrypt fine (`fox.decrypt.state=done`), password page rejects the correct password | Gatekeeper (or Weaver on Pixel-class devices) HAL missing / not started; wrong synthetic-password format handling | start `gatekeeper-1-0-qti` from the listeners trigger (the common rc does); add Weaver where the ROM has it | partly seen (password worked once Gatekeeper ran) |
| 11 | no `prepdecrypt::` lines at all | the trigger `ro.crypto.state=encrypted && ro.boot.dynamic_partitions=true` never fired: command line lacks `androidboot.dynamic_partitions=true`, or the recovery did not classify `/data` as encrypted (no `fileencryption=` in twrp.flags) | fix the command line / flags | read-from-source |
| 12 | `dlopen ... libsecureui.so/libspl.so/libops.so not found` from QSEECOMD | optional libraries | none (do not add libops.so) | seen, harmless |
| 13 | `Upgrading key: .../keymaster_key_blob` for every key | fake high patch level makes the TA return upgraded blobs; they stay in `/tmp` | none | seen, expected |
| 14 | `E KeyStorage.cpp: key mkdir /tmp/keymaster_key_blob/: File exists` | second and later upgrades find the RAM directory | none | seen, harmless |
| 15 | `Unhandled flag: 'reservedsize=128M'`, `'checkpoint=fs'` | fstab flags the recovery's fs_mgr does not know | none | seen, harmless |
| 16 | `F2FS-fs (sdaXX): Magic Mismatch` / `Can't find valid F2FS filesystem` before the decrypt | the kernel probed the encrypted raw partition | none | seen, harmless |
| 17 | kernel `Unable to handle kernel paging request` at a random time, `Kernel panic - not syncing` | memory corruption in the kernel, not decryption | `recovery-boot-debugging` | seen |

## 3. Reading the "Decrypt: waiting" line (patched recovery, every 5 s, up to the timeout)
```
Decrypt: waiting for the decryption services (15s): init.svc.servicemanager=running init.svc.hwservicemanager=running init.svc.keystore2=restarting
  init.svc.prepdecrypt=stopped init.svc.qseecomd=running init.svc.keymaster-4-1-qti=running init.svc.gatekeeper-1-0-qti=running
  hwservicemanager.ready=true crypto.ready=1 vendor.sys.listeners.registered=true keymaster_ver=4.x
```
`prepdecrypt=stopped` is normal (oneshot). The first long-running service that is not `running` is the broken link; `crypto.ready=1` plus `hwservicemanager.ready=true` should precede qseecomd;
`vendor.sys.listeners.registered=true` should precede the HALs. After the timeout (`fox.decrypt.timeout`, default 90 s) the log has `Decrypt: the metadata decrypt did not finish` and the UI comes up without `/data`.

## 4. When the log is silent
* No `Starting the UI...`: the recovery binary died or hung before the GUI (display, theme, SELinux): `recovery-boot-debugging`.
* UI log present, no decrypt lines: the build has no crypto (nocrypt variant), or `Decrypt_Data()` was not reached. Check `TW_INCLUDE_CRYPTO*` and that `/data` is classified as encrypted.
* adb silent and no log: kernel panic before userspace.

## 5. Success markers (in order)
`Keymaster_Ver::Using keymaster version '4.x'` -> `Starting the UI...` -> `fscrypt_mount_metadata_encrypted: /data encrypt: 0 format: 0 with f2fs` -> `Key exists, using: /metadata/vold/metadata_encryption/key` ->
`prepdecrypt::Script complete` -> `Retrieving key from keymaster` -> `Upgrading key` -> `Mounting metadata-encrypted filesystem:/data` -> `Running /system/bin/fsck.f2fs -a` ->
`Successfully decrypted metadata encrypted data partition with new block device: '/dev/block/dm-5'` -> `fscrypt_initialize_systemwide_keys` -> `fscrypt_init_user0` -> `Installed de key for user 0` ->
`Verified that /data/system_de/0 has the encryption policy ... v2` -> (password) `User 0 Decrypted Successfully`.
