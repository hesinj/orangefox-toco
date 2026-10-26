# Reading the deaths of a boot that fails often (death-window analysis)

Use it when a recorder (`scripts/fox_blackbox.sh`) has left logs of several boots, some of which died and some of which lived, and nothing names the cause. It turns "about half of the boots freeze" into a question that a build can answer.

## Contents
1. Tabulate the boots
2. Do not read the last line as the freeze point
3. Compare with the survivors
4. Is it clustered?
5. Make the next recorder better
6. Remove one event at a time
7. Look at the frozen phone from the PC
8. Wording

## 1. Tabulate the boots
One row per numbered log: boot number, file time, size, the last `===== uptime T` header, the last kernel line and whether it survived (a survivor has snapshots for the whole recording time). The size alone tells how many snapshots a dead boot got (the first ones are about 1 KB each).
A boot that dies before the recorder starts (7-8 s on the reference phone) leaves no numbered log at all; neither does a restart by the watchdog. The table counts boots that reached the recorder, say so when reporting a rate.

## 2. Do not read the last line as the freeze point
* A snapshot is read some half a second after its header, so the last kernel line only says what had happened by then; the freeze lies between that read and the moment the next snapshot would have been written (cadence 3 s on the reference phone, 2 s of sleep plus the work).
* Snapshots are phase-locked to the recorder start, which is itself locked to the boot flow: in the reference case the second snapshot fell on the USB gadget start in **all** boots, survivors included, so "the log ends at the USB event" proved nothing until the survivors' logs showed the same line.
* A filter in the recorder (`FOX_BB_NOISE`) hides exactly the drivers that are talkative around power and USB events. Keep raw lines (section 5).

## 3. Compare with the survivors
Take a surviving boot's log and list every event inside the dead boots' window: service starts and exits (`init:` lines), mounts, USB gadget lines (`Avail curr from USB`, `USB_STATE=`), one-shot scripts that run at a fixed delay (a diagnostic with `sleep 4`), property sets by the recovery. That list is the suspect list.

## 4. Is it clustered?
If all dead boots stopped inside one short window (the reference phone: four boots inside 11.5-14.2 s, none before, none after, two survivors that lived for minutes and hours), the hazard is tied to an **event in the boot flow**; if the deaths were spread over the first 20-30 s it is more like random hardware or memory corruption.
A rough check: with k deaths in a window of w seconds out of a plausible hazard span of S seconds the chance is about (w/S)^k; here (2.7/17.5)^4 is below 0.1 %. Four deaths is a small sample; say what it supports and what it does not.

## 5. Make the next recorder better
* Log raw kernel lines and filter when reading.
* A tiny static logger that blocks on `/dev/kmsg`, writes each record to a file on `/cache` and calls `fdatasync` per record (ext4 only, never `sync` while `/data` is mounted read-write), plus a heartbeat line with the uptime every 100 ms: the last line is then within 0.1 s of the end.
* In the header: the PMIC lines (`dmesg | grep qpnp-power-on`: `Power-on reason ... 'cold'/'warm' boot`, `Power-off reason`: PS_HOLD, KPDPWR, UVLO, over-temperature), the `androidboot.*` fields of the command line, and what the previous reboot was (software reboot, long power-key hold, nothing).
* Keep it passive (`recorder-and-observer-effect.md`); a logger that only reads `/dev/kmsg` and writes one file does not touch sensors or hardware.

## 6. Remove one event at a time
Each of these is an image or a user action, one per test, eight boots each (if nothing changed and two boots in three still die, at most one failure in eight boots has a chance well under 1 %):
* the nocrypt twin (no decrypt stack, no one-shot diagnostic, no `/data` mount);
* the one-shot diagnostic off;
* the USB gadget delayed by a minute (the PC cannot talk to the phone for that time; the recorder file is read afterwards);
* **no cable at all** during the boot (the user starts the phone from the key combination; or unplugs right after `fastboot boot` says OKAY);
* the ROM's own recovery, as a control, with the same count.
Write each result as a sequence (ok ok frozen ok ...), not only a count: a pattern such as "only the first boot after a different image fails" is itself evidence.

## 7. Look at the frozen phone from the PC
Free observations when a boot freezes (ask for them, they cost a minute):
* `adb devices -l` and `fastboot devices`: does the phone still show up (the kernel and USB alive), or did the USB device vanish?
* `adb shell` and `adb shell dmesg | tail -n 60`: if the shell answers, run `echo w > /proc/sysrq-trigger` and read the blocked tasks (a shell started from the ramdisk needs no disk).
* Does it restart by itself within a minute? The APSS watchdog (`qcom,wdt` node: `qcom,bark-time` 20 s, `qcom,pet-time` 15 s on the reference phone) should reset a hung CPU after about that long; `androidboot.ramdump=disable` means no dump is written.
* A live copy of the kernel log on the PC survives any freeze that leaves USB alive: start `adb wait-for-recovery shell "cat /dev/kmsg" > live-kmsg.txt` in a second window **before** `fastboot boot`; it waits, attaches as soon as adb appears and replays the ring buffer from boot 0. It cannot show anything after the USB link dies.
The retention of the pstore console is itself unreliable: it held the console after a kernel panic that ended in a forced restart, and was empty after software reboots and after silent freezes. Do not conclude "no panic" from an empty pstore.

## 8. Wording
"Four of the six recorded boots stopped between 11.5 s and 14.2 s; the events in that window are A, B, C; not yet separated" is a finding. "USB kills the boot" is a guess until a boot without the event survives about as often as the ROM's own recovery.
