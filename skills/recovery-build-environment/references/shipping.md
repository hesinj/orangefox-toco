# Shipping a recovery build

## Contents
1. What a release contains
2. Collecting the files
3. Release notes: template
4. Provenance and licences
5. Whose step is publishing
6. Changelog discipline

## 1. What a release contains
Per tag (`r8`, `v1.0`): the `full` and `nocrypt` images (`.img` flashable to `recovery` or bootable with `fastboot boot`, `.zip` for installation from a recovery), `SHA256SUMS`, the notes, and a log collector for the user (`recovery-boot-debugging/scripts/collect-logs.bat` / `.sh`).
Keep the nocrypt twin in every release: it is the control image, and the fallback when the full image misbehaves.

## 2. Collecting the files
`scripts/run_release.sh DEVICE TAG [OUTDIR]` builds both variants (logs `build_TAG_full.log`, `build_TAG_nocrypt.log`), copies `NAME-TAG.img/.zip` (`cp --sparse=always`) and writes `SHA256SUMS`. Run `scripts/verify_image.sh` on each `.img` afterwards and put the count in the notes.
Give the user the files by the channel they can reach (the chat's file delivery, a Drive upload). A GitHub Release with binaries is created by the repository owner: say so plainly; do not pretend that pushing source publishes binaries.

## 3. Release notes: template
```
**Status line in bold: what has and has not been shown on a phone.**  (e.g. "booted, decrypted /data, adb pull worked: one reported session")

### What the previous build showed          (one short paragraph with the evidence, not the guesses)
### Changes since the previous build        (one line each, every line is one variable)
### Files                                    (name + sha256 for every .img/.zip; "exactly <partition size>, AVB footer")
### Try it                                   (the exact commands; fastboot boot does not change the phone; how many boots to do and what to send back)
### Limits                                   (supported encryption types, unverified paths, what was only checked statically)
Provenance paragraph: kernel (source repository, commit, whether the binary is the ROM's, sha256), patches, vendor binaries -> NOTICE.md
```
Rules for the wording: say "static checks only" when only static checks were done; say "one reported session" for one success; never "fixed" for something observed once; put the data-safety line next to the commands (`Do not use Format Data or Wipe: while /data is not decrypted they would destroy it`).

## 4. Provenance and licences
Keep a `NOTICE.md`: original configuration (licence header), files copied from another device tree (source, unchanged or not), the OrangeFox patch (GPL-3.0-or-later like the files it touches, base commit), the kernel (GPL-2.0: repository, branch, commit; for a ROM binary the byte-for-byte statement and sha256; the source offer), proprietary vendor binaries (which ROM build they came from: they must match the firmware on the phone, `recovery-fbe-decryption/references/ramdisk-contents.md`).
Do not claim a licence you have not checked, and do not redistribute binaries whose redistribution you cannot justify; say what they are.

## 5. Whose step is publishing
Pushing source to the repository can be done on request. Creating a Release, uploading binaries, or posting to a forum is the owner's step: give the owner the exact files, the sums and the notes text, ready to paste. Sending a file to an external service publishes it (it may be cached or indexed even if deleted later): confirm first.

## 6. Changelog discipline
One line per image: tag, what changed relative to the previous image, and the evidence it was aimed at. If an image changes several things at once (as the reference port's r8 did: command line, scheduler, recorder, ramdisk compression), say so, and say that it is therefore unknown which change mattered. A release table that lists unproven precautions as fixes is what the next maintainer will believe.
