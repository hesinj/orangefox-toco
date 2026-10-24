# Troubleshooting

This tree has been built but **never run on the device by its author**. Everything below comes from
logs that users sent back, so please send logs (see "Collecting logs").

## What was seen so far

`fastboot boot` of the first builds (`r1`, `r2`):

* **Mac, first try:** OrangeFox logo for a moment, then the phone went back to the installed system.
* **Windows, second try:** stuck on the OrangeFox logo for good, but `adb` answered and
  `/tmp/recovery.log` could be pulled.

That log (r2) ends like this:

```
Starting the UI...                       <- display, fstab, vendor props: all fine
...
Settings storage is '/data/media'
Using additional fstab for decryption /etc/additional.fstab
I:prepdecrypt::Script complete. Device ready for decryption.
                                         <- nothing after this line
```

So the kernel, `init`, the display and OrangeFox itself were running. The recovery process was blocked inside
the decryption of `/data`, which sits between "logo" and "menu" in OrangeFox's start-up. The logo
is only replaced by the menu after that step returns.

**Second report (`r3`):** the `-nocrypt` image came up and was usable, so the kernel, display, touch, USB, `adb` and
OrangeFox's own UI work on the device. The full image got stuck again (log pending). That narrows the problem down to the
decryption chain.

### Why decryption can block forever

`/data` of PixelOS (Android 16) uses metadata encryption with a hardware-wrapped key. To open it the
recovery process asks a chain of services, and each waits for the next without a time limit:

```
recovery (vold code) -> keystore2 -> Keymaster 4.1 HAL -> qseecomd -> TrustZone
```

* `qseecomd` must first set up two things as root and refuses to continue if either fails
  (`RPMB_INIT failed` or `SSD_INIT failed` in logcat, tag `QSEECOMD`): the UFS RPMB device (`/dev/sg*`)
  and the `ssd` partition. Only then does it start its listeners and set
  `vendor.sys.listeners.registered`, which is what starts the Keymaster HAL.
* keystore2 waits for the Keymaster HAL to register with `hwservicemanager`.
* If one of these never comes up, OrangeFox used to wait on the splash screen for ever.

Which link failed on the device is **not known yet**. The next builds are made to find out.

## What r3 changes

* The decrypt step runs in a worker thread and gives up after 90 seconds (property `fox.decrypt.timeout`,
  minimum 10). The OrangeFox menu then comes up (with a password prompt, but without access to `/data`)
  and `adb` keeps working.
* While waiting, `recovery.log` shows the state of every link every 5 seconds
  (`Decrypt: waiting for the decryption services ...`).
* `fox_decrypt_diag.sh` appends, at about 4, 15, 40 and 90 seconds after `prepdecrypt`, and once more when
  the recovery gives up, a block starting with `fox-diag:` to `/tmp/recovery.log` (also
  `/tmp/fox-decrypt-diag.log`): service states, process list with wait channel, device nodes
  (`/dev/qseecom`, `/dev/sg*`, `by-name`), the `QSEECOMD` / keystore / vold lines from logcat and the
  related kernel messages.
* libbase logging of the recovery process (vold's metadata decrypt) now also goes to `recovery.log`.
* The `modem` partition is mounted read-only at `/vendor/firmware_mnt` from `init`. The Keymaster
  library loads its trusted app from that fixed path when the secure world does not have it yet.
* A stale `libops.so` that earlier builds carried in the image is gone. It was left in the build
  output directory after the file had been removed from the tree. The images are now checked against
  the tree (`tools/verify_image.sh`).
* A second image, `-nocrypt`, has no decryption stack at all. If the plain recovery comes up and the
  full one does not, the problem is in the decryption chain and not in the kernel, display or touch.

The source changes to OrangeFox are in `patches/0001-toco-startup-hardening.patch`.

## Probing the services by hand (needs the `-nocrypt` image)

The `-nocrypt` image does not start the decryption services, but their binaries are in its ramdisk. `tools/toco-probe.sh`
starts them one by one in the order the full image uses (qseecomd, Keymaster 4.1 HAL, gatekeeper HAL), waits, and reports for
each: still running or not, the kernel function every thread sleeps in, and the relevant logcat/dmesg lines. It never touches
`/data`, `/metadata` or a key.

```
adb push toco-probe.sh /tmp/toco-probe.sh
adb shell sh /tmp/toco-probe.sh
adb pull /tmp/toco-probe.log
```

(`tools/toco-probe.bat` does the same on Windows.) Every step is printed before it runs, so if the phone freezes or restarts,
the last line on the PC says which step it was. Reading the result:

| Result line | Meaning |
|---|---|
| `qseecomd is NOT running` | the first mandatory step failed; the log lines above it (`RPMB_INIT failed`, `SSD_INIT failed`, ...) say which |
| `qseecomd runs but never reported its listeners as registered` | it is stuck inside a listener start |
| `the Keymaster HAL exited` | qseecomd is fine; the HAL could not load its trusted app or register |
| all three `yes` | the services are fine; the stall is above them (keystore2 or the recovery's own decrypt call) |
| the phone freezes or restarts at a step | that step crashes the secure world or the kernel |

## Collecting logs

Boot the image first (the phone in fastboot mode):

```
fastboot boot OrangeFox-R12.0-Unofficial-toco-r3.img
```

**Windows:** copy `tools/toco-logs.bat` next to `adb.exe` and run it (`toco-logs.bat recovery.img` boots the
image first, then collects twice). It leaves a folder and a zip on the Desktop.
If `adb devices` stays empty while the phone shows the logo, Windows has no driver for the phone in
recovery mode: install the Google USB driver or the Xiaomi USB driver.

**macOS / Linux:** `tools/toco-capture.sh recovery.img` does the same and writes to `~/toco-logs/`.

**By hand**, from any shell with `adb`:

```
adb shell "dmesg > /tmp/dmesg.txt; logcat -d -b all -v threadtime > /tmp/logcat.txt; getprop > /tmp/getprop.txt; ps -A > /tmp/ps.txt"
adb pull /tmp/recovery.log
adb pull /tmp/dmesg.txt
adb pull /tmp/logcat.txt
adb pull /tmp/getprop.txt
adb pull /tmp/ps.txt
```

## Reading `recovery.log`

| Line / block | Meaning |
|---|---|
| `Starting the UI...` and `Atomic Commit succeed` | display works |
| `prepdecrypt::Script complete` | `crypto.ready=1` was set, the service chain should now start |
| `Decrypt: waiting for the decryption services (Ns): ...` | the chain is still not ready; see which `init.svc.*` is not `running` |
| `init.svc.qseecomd=stopped` and logcat `QSEECOMD ... RPMB_INIT failed` / `SSD_INIT failed` | `qseecomd` quit; check the `/dev/sg*` and `by-name/ssd` lines of the block |
| `init.svc.qseecomd=running`, `vendor.sys.listeners.registered` empty | listeners did not finish |
| `vendor.sys.listeners.registered=true`, `init.svc.keymaster-4-1-qti` not `running` | Keymaster HAL did not start or crashed; look at logcat for its message |
| everything `running` but still waiting | keystore2 or the trusted app in TrustZone does not answer |
| `Successfully decrypted metadata encrypted data partition` | `/data` is open |

## What the phone does and what it means

| Phone | Meaning |
|---|---|
| OrangeFox menu with internal storage visible | decryption works |
| OrangeFox menu after about 90 s, "Decryption services did not answer in time" | the recovery works; send `recovery.log` |
| Stuck on the logo for more than 3 minutes, `adb` answers | send the logs |
| Frozen on the logo, `adb` silent, buttons dead | probably a kernel panic (this build uses `panic=0` so it freezes instead of rebooting); hold power for about 10 s and try the `-nocrypt` image |
| Restarts into the installed system | something reset the phone (panic with reboot, watchdog); try `-nocrypt` and tell what you saw |
| Fastboot screen | `init` hit a fatal error and rebooted to the bootloader |

## Data safety

`fastboot boot` writes nothing to the phone. While `/data` is not decrypted nothing can be read from
internal storage over `adb` or MTP, and **Format Data / Wipe in the menu would destroy it**. Do not use
them. To copy files off the phone meanwhile, boot the installed system normally.
