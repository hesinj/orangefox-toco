# Other SoCs and other key stacks (UNVERIFIED: reasoning from how the stack works, not from a port)

The reference port is Qualcomm (SM6150) with a Keymaster 4.x HIDL HAL. What follows is where other devices are likely to differ and how to find out, so that the next port starts from
questions instead of guesses. Mark everything you do on these as unverified to the user until a boot proves it.

## The method that works everywhere
The ROM already runs the whole stack at boot. **Mirror what the ROM's init does for the key HALs.**
1. In the running ROM: `ls /vendor/bin/hw | grep -i -E 'keymaster|keymint|gatekeeper|weaver|secure|rkp'`; `grep -h -A14 -E '^service .*(keymaster|keymint|gatekeeper|weaver)' /vendor/etc/init/*.rc` (the facts script prints both).
2. The service stanza gives the binary, `user`, `group`, capabilities, `class`, environment and what it needs started before it (`class early_hal`, `onrestart`, `interface aidl ...`).
3. `/vendor/etc/vintf/manifest.xml` (and `/vendor/etc/vintf/manifest/*.xml`) gives the HAL interface and version: HIDL `android.hardware.keymaster@4.x`, or AIDL `android.hardware.security.keymint` (version in the entry), gatekeeper, weaver.
4. In the recovery rc: the same binary, `user root`, `disabled`, `oneshot`, `seclabel u:r:recovery:s0`, started from a property trigger after whatever the stanza says it depends on. Declare the interface in the ramdisk's device manifest. Add the binary's library closure (`collect_decrypt_blobs.py --pattern`, then `verify_ramdisk.py`).
5. If the ROM has a daemon that the HAL talks to (`qseecomd` on Qualcomm, `teed`/`mobicore`/`tee-supplicant` elsewhere), find it the same way and start it first.

## Where devices differ (what to check, not what to expect)
| area | Qualcomm (verified) | other vendors (expectation, unverified) |
|---|---|---|
| TEE daemon | `qseecomd`, RPMB + SSD listeners, firmware at `/vendor/firmware_mnt` | MediaTek: `teei`/`microtrust`/`trustonic`/`beanpod` daemons, firmware partitions (`tee1`, `tee2`), different `ro.hardware`; Exynos: Samsung TEEgris/`tlc_server`; Tensor: Trusty/Titan M (`citadel`), Weaver mandatory |
| Keymaster/KeyMint | HIDL 4.x, `keymaster_ver` | Android 13+ vendors may ship only the AIDL KeyMint HAL (`android.hardware.security.keymint-service.*`); the HIDL path of this skill would then need keystore2 to talk AIDL directly (no km_compat) and the common TWRP init files may lack the service names: write the stanza from the ROM |
| key blob format | upgrade-in-place with commit disabled | same code path (TWRP's vold); a device whose TA refuses a fake patch level needs the real values (set `prepdecrypt.setpatch`/`SETPATCH` handling or `TW_OVERRIDE_...`) |
| user password check | Gatekeeper HAL | Weaver (`android.hardware.weaver`) on Pixel-class devices, with the TA in the secure world; Samsung has its own flow |
| hardware-wrapped keys | UFS ICE with Qualcomm key manager | MediaTek/Exynos use their own crypto engines; the kernel needs the vendor's driver and the data-unit/dun settings in the flags |
| partition/firmware layout | `modem`, `persist`, `ssd`, `keymaster`, `cmnlib` | different names; read the by-name list |
| boot flow | A-only + recovery partition (verified); A/B recovery-in-boot (not covered) | `vendor_boot` + `boot` (header v3/v4), GKI kernels, `first_stage_ramdisk` |

## Questions to put to the ROM before writing any rc
* Is the keymint/keymaster service HIDL or AIDL, which version, which binary, which `class`?
* Which daemon does it need, and does that daemon read firmware from a partition?
* Which files/devices does it open (`strace` is not available; `ls -l /proc/<pid>/fd` and `/proc/<pid>/maps` of the running service show device nodes and libraries)?
* Does the ROM start anything from `on early-init` / `on fs` that touches `/dev/qseecom`-like nodes first (permissions!)?
* What does `getprop | grep -E 'keymaster|keymint|gatekeeper|weaver|crypto|vold'` say about the versions it expects?

## When it does not work
Use the same diagnostics: `fox_decrypt_diag.sh` lists processes with their wait channel, device nodes, the logcat lines of the HALs and keystore2 and the kernel lines about the TEE; the first service that never reaches `running`
or never registers with hwservicemanager/servicemanager is the link to fix. Add the vendor's names to `SVC_RE`/`PROC_RE` at the top of the script.
