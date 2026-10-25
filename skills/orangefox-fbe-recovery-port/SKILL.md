---
name: orangefox-fbe-recovery-port
description: End-to-end workflow for building a custom OrangeFox (or TWRP) recovery for an Android phone so that it boots reliably AND can decrypt and read the encrypted /data (file-based encryption, metadata encryption, hardware-wrapped keys) of a modern ROM. Use this whenever the user wants to port or build OrangeFox or TWRP for a device or a new ROM or Android version (12 to 16, PixelOS, LineageOS, custom ROMs), says the recovery shows 0 MB or 'encrypted' internal storage or asks for a password it cannot use, wants to rescue files from an encrypted phone through recovery, or asks for a device tree, BoardConfig or recovery.fstab for a recovery - even if they never say 'decryption' or 'FBE'. It holds the safety rules, the intake checklist, a tested device-tree generator, the staged test ladder, and routes to the sibling skills for decryption internals, boot debugging, the build machine and copying data off the phone.
---

# Port OrangeFox / TWRP to a phone and make it read an encrypted /data

This skill is the entry point. It was written from a real port (Xiaomi Mi Note 10 Lite "toco", Snapdragon 730G, userdata
of PixelOS / Android 16 with FBE v2 + metadata encryption + hardware-wrapped keys) that took eight image revisions.
Most of those revisions were avoidable; the point of this skill is that the next port takes two or three.

Paths below are relative to this skill's directory. Sibling skills (installed next to this one):
`recovery-fbe-decryption`, `recovery-boot-debugging`, `recovery-build-environment`, `android-data-rescue-adb`.

## What is verified, and what is not

Verified on one device (SM6150, A-only with a dedicated recovery partition, dynamic partitions, boot header v2, Qualcomm
TEE with a Keymaster 4.1 HIDL HAL, OrangeFox branch `fox_12.1`): boot, display, touch, adb, `/data` decryption of PixelOS
Android 16 userdata including the lock-screen password, `adb pull` of the internal storage. Everything for other SoCs
(MediaTek, Exynos, Tensor), A/B or vendor_boot devices, AIDL KeyMint vendors is reasoned from how the stack works and is
marked "unverified" in the references. Say so to the user instead of promising.

Stability across many boots was not proven on the reference device; one stable session was reported. Do not promise "stable".

## Ground rules (they cost real data and real time when ignored)

1. **Protect the user's data.** While `/data` is not decrypted, "Format Data" and "Wipe" in the recovery destroy it. Never
   suggest them, never run `mkfs`, `dd` to a block device, `fastboot erase/flash` of anything but the recovery slot, or
   `rm -r` on the phone, unless the user states the exact scope. If a command could delete more than the user described
   (for example "delete Android/data"), ask which exact folder first.
2. **Boot images with `fastboot boot` first.** It writes nothing. Flash to `recovery` only after several clean boots, and
   never to `boot`. Keep the ROM's own recovery image at hand as a control.
3. **Evidence before theory.** Every failed boot costs the user a cable swap, a button dance and a report. Get logs
   (`recovery-boot-debugging`, `scripts/` there), read them, and name the single most likely cause before changing anything.
4. **One variable at a time when tests are cheap; a planned bisect when they are not.** Keep a change table per image
   (what differs from the previous one). Changing five things at once and finding a stable image teaches nothing.
5. **Report faithfully.** "Static checks passed" is not "it works"; "booted once" is not "stable"; a root cause that was
   not proven is a hypothesis. Mark each statement verified or unverified.
6. **Work in the user's language and keep their burden small.** The user is usually tired of failed boots. Ask for one
   thing at a time, say what the test proves, give a single copy-paste command or script, and explain the phone's
   reaction in plain words (see `references/test-ladder-and-safety.md`).
7. **Binaries belong to the user's release step.** Vendor blobs (qseecomd, HALs) are proprietary and come from the
   device's own ROM; the kernel is GPL. Keep a NOTICE with provenance. Do not publish blobs you cannot account for.

## The workflow

### 0. Frame the job (ask only what the facts cannot tell)
Phone and codename; the ROM whose `/data` has to be read (name + Android version); is the bootloader unlocked and does
`fastboot boot` work; does the user know the lock-screen secret (needed for the CE keys, not for the metadata layer);
is there an official OrangeFox/TWRP/PixelOS recovery for the device already (try it before building anything); how much
disk and RAM the build machine has (`recovery-build-environment`: at least 60 GB disk, 16 GB RAM).

### 1. Collect facts from the running ROM
Run `scripts/collect_device_facts.sh` on the phone (header of the script shows the adb one-liner) and save the output.
Run `scripts/unpack_and_inspect_boot.sh` on the stock recovery image (header version, offsets, page size, command line)
and on the ROM's `boot.img` (its kernel and dtb). `references/intake-checklist.md` lists every fact, where it comes from
and which line of the tree it ends up in.

### 2. Decide the crypto mode from the ROM's fstab
Take the `userdata` line of the ROM's `/vendor/etc/fstab.*` (it is in the facts output).

| flags in the fstab line | `CRYPTO_MODE` | what the recovery needs |
|---|---|---|
| no `fileencryption=`, `forceencrypt`/`encryptable` | `fde` | block-device encryption (old devices, Android 9 and older) |
| `fileencryption=` only | `fbe` | FBE; `TW_USE_FSCRYPT_POLICY` 1 or 2 by the `:v2` suffix |
| `fileencryption=` + `metadata_encryption=` | `fbe_metadata` | plus `/metadata` partition and dm-default-key |
| the above with `wrappedkey_v0` / `inlinecrypt_optimized` | `fbe_metadata_wrapped` | plus a kernel with inline-crypto + wrapped keys, and the whole TEE chain |
| none of these | `none` | the data is not encrypted; skip the decryption skill |

`recovery-fbe-decryption` explains the chain, the flags, the ramdisk contents and the failure signatures.

### 3. Choose the kernel (this decided everything on the reference device)
The recovery's kernel must understand everything the userdata uses (fscrypt v2 policies, inline crypto, wrapped keys,
f2fs compression, EROFS for logical partitions). The old stock kernel of the device did not (MIUI 4.14.117 had none of
them). Use **the kernel binary of the ROM itself, unchanged**, from its `boot.img`. A kernel rebuilt from the same source
with a different compiler panicked in about half of the boots (`recovery-boot-debugging`). Build your own kernel only when
no ROM kernel exists, and then with the ROM's compiler. `recovery-fbe-decryption/scripts/kernel_marker_check.sh` gives a quick
yes/no on the features by looking for marker strings in a kernel image.

### 4. Generate the device tree
```
cp assets/device.conf.template device.conf        # fill it from the facts; assets/device.conf.example is a complete one
python3 -I scripts/new_device_from_template.py --conf device.conf --out <fox>/device/<oem>/<codename> --ueventd <ref>/ueventd.<hw>.rc
```
The generator renders BoardConfig.mk, device.mk, fox_<codename>.mk, twrp_<codename>.mk, vendorsetup.sh, init rc files,
recovery.fstab, twrp.flags, the VINTF manifests, the diagnostic scripts and the OrangeFox patch, then lists every
`TODO(port)` that still needs a decision. Rendering `device.conf.example` reproduces the working toco tree, so the template is
as proven as that tree. `references/device-tree-guide.md` explains each file and the A/B / vendor_boot cases the template does not cover.

### 5. Add what the generator cannot invent
* kernel, dtb, dtbo into `prebuilt/` (step 3);
* `ueventd.<hw>.rc` from an official tree of the same SoC (device nodes and permissions: `/dev/qseecom`, `/dev/ion`, `/dev/sg*`, display, touch);
* the decryption blobs (`recovery-fbe-decryption/scripts/collect_decrypt_blobs.py`, from the ROM's vendor image) and a clean
  `verify_ramdisk.py` run;
* the OrangeFox patch: `cd <fox>/bootable/recovery && git apply <tree>/patches/0001-startup-hardening.patch`
  (bounded decrypt with logging, libbase logs into recovery.log, hold instead of reboot when the GUI fails; it applies to
  `fox_12.1` at 4f00a3d);
* a reference for anything device specific (brightness path, touch blacklist, screen size, USB controller) from an official tree.

### 6. Build both variants, verify statically
`recovery-build-environment` has the scripts. Always build **`full`** and **`nocrypt`** (`FOX_VARIANT=nocrypt`): the nocrypt
twin never starts the TEE daemon, the HALs or keystore2, so it separates "the kernel/ramdisk/display is broken" from "decryption
is broken". Run `verify_image.sh` on each image before handing it over, and keep a one-line changelog per image.

### 7. Test ladder (details and wording in `references/test-ladder-and-safety.md`)
1. Control: the ROM's own recovery (or any known good image) boots via `fastboot boot` -> cable, driver and bootloader are fine.
2. `nocrypt` image: boots? touch and adb work? -> collect logs with `recovery-boot-debugging/scripts/collect-logs.*`.
3. `full` image: watch `fox.decrypt.state`, read `recovery.log` with `recovery-fbe-decryption/scripts/analyze_recovery_log.py`.
4. Password page -> unlock -> `android-data-rescue-adb` copies the data off. **Copy data before testing anything else.**
5. Stability: five boots in a row, then report the count. Only then consider flashing the recovery partition.

### 8. When it does not work
* log stops after `prepdecrypt ... Device ready for decryption`, or "Decryption services did not answer in time" ->
  `recovery-fbe-decryption/references/failure-signatures.md`;
* freeze, restart into the ROM, logo forever, adb silent -> `recovery-boot-debugging` (kernel panic until proven otherwise;
  read pstore first);
* password rejected after the metadata layer opened -> gatekeeper / weaver (`failure-signatures.md`).

### 9. Ship
Release notes with the sha256 of every image, the change table, the verified/unverified list, the kernel and blob provenance
(`recovery-build-environment/references/shipping.md`). Tell the user clearly that publishing binaries is their step.

## Where things are
* `references/intake-checklist.md`: every fact needed, where to get it, where it goes.
* `references/device-tree-guide.md`: each generated file, flags, pitfalls, A/B and recovery-in-boot.
* `references/test-ladder-and-safety.md`: test protocol, how to ask the user, data-safety rules, what each phone reaction means.
* `references/toco-case-study.md`: the full timeline of the reference port with what each revision taught.
* `scripts/collect_device_facts.sh`, `scripts/unpack_and_inspect_boot.sh`, `scripts/new_device_from_template.py`.
* `assets/device-tree-template/` (the template), `assets/device.conf.template`, `assets/device.conf.example`.
