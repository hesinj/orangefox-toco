# The black-box recorder and the observer effect

## The recorder (`scripts/fox_blackbox.sh`)
Started from the recovery's init (`on boot: start fox_blackbox`), it waits for `/cache`, then writes `/cache/fox-bb/boot-N.log` (the last four boots are kept) with `sync` after every snapshot:
* once per boot, a header: kernel banner, command line, `/proc/iomem` (RAM, kernel image, reserved ranges), the ramdisk range from `/proc/device-tree/chosen/linux,initrd-start/end`, the pstore listing and a copy of `console-ramoops-0` of the previous boot as `pstore-before-boot-N.txt`;
* every 2 s for the first 150 s, then every 10 s, for about 15 minutes: uptime, load, `MemFree/Slab/SUnreclaim`, the state of the decryption services (init properties only), processes in D/T/Z state, where the recovery's threads sleep (`/proc/<pid>/task/*/wchan`), and the kernel log lines since the previous snapshot (noise filtered with `FOX_BB_NOISE`).
Fetch with `adb pull /cache/fox-bb` (the collectors do). It writes only to `/cache`, never to `/data` or `/metadata`.

## The rule: a recorder must never be an extra suspect
The first version (r7 of the reference port) also read CPU frequencies, every thermal zone, the battery gauge and the kernel stacks of blocked tasks. Of the r7 boots, three of three failed; the two with recorder logs stopped within a second or two of the first snapshot with no panic text,
at the time the decryption services started. Whether the sensor reads caused the freezes was never proven (the other r7 changes could not be ruled out either), but they could not be excluded, and the next image without them booted.
Therefore:
* read only procfs, init properties and the kernel log;
* do not read `/sys/class/thermal`, `/sys/class/power_supply`, cpufreq, i2c/SPI device nodes, `/proc/*/stack`, debugfs, or anything that makes a driver talk to hardware, in the first minutes of a boot that is under suspicion;
* do not start the recorder before `/cache` is mounted, and do not let it block (timeouts on every wait);
* every added diagnostic is a new variable: add it in an image of its own, or keep it off in the release.

## Other observer effects seen
* `logcat -d` in a loop at the wrong moment delays the services you are timing; the diag script snapshots at T+4/15/40/90 s only.
* A probe that starts the TEE daemon by hand changes the order of the boot: use it in a nocrypt image, and write every step to `/dev/kmsg` first (`probe_services.sh`), so that a freeze leaves the step in pstore.
* Collecting logs over adb while the phone is unstable (`echo w > /proc/sysrq-trigger`) is useful only when adb answers; the collectors do it last and with timeouts.
* `fastboot boot` of an image while the bootloader's USB session is still live is a different starting condition from a flashed recovery started with the key combination; both were tried, neither explained the freezes.

## Reading a recorder file
`boot-N.log`: header lines first (check `cmdline`, `linux,initrd-start/end`, `/proc/iomem`), then `===== uptime T` blocks. A log that stops right after the header means the boot died within about a second of the recorder start;
compare T with the service start times in `getprop ro.boottime.*` of a good boot (qseecomd about 8.3 s, Keymaster about 8.35 s on the reference phone). `pstore-before-boot-N.txt` is the previous boot's console: check its last lines for `Kernel panic`.
The last kernel line of a dead boot is where the last snapshot's read stopped, not where the boot died; the snapshots are phase-locked to the boot flow and the filter drops charger, battery, touch and USB-PD lines. Compare with surviving boots and count deaths per time window (`death-window-analysis.md`).
