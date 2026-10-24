# Notices and provenance

This repository mixes original configuration with third-party binaries. Each group is listed
with where it came from, so you can judge what you are redistributing.

## Original configuration
`BoardConfig.mk`, `device.mk`, `fox_toco.mk`, `twrp_toco.mk`, `AndroidProducts.mk`, `Android.mk`,
`vendorsetup.sh`, `recovery/root/init.recovery.*.rc`, `recovery/root/system/etc/*`, the vintf
manifest and the scripts/docs. Where a file carries an SPDX header it is `Apache-2.0`. The fstab
flags follow the public PixelOS `sm6150-common` fstab and the structure follows OrangeFox's
`sweet` device tree; the USB gadget script is adapted from that tree.

## Copied from the OrangeFox `sweet` device tree: `recovery/root/ueventd.qcom.rc`
The Qualcomm SM6150 ueventd rules (device node permissions, firmware search path) are taken
unchanged from OrangeFox's `sweet` tree (<https://gitlab.com/OrangeFox/device/sweet>). The file keeps
its Linux Foundation BSD-style header.

## Patch to OrangeFox: `patches/0001-toco-startup-hardening.patch`
A patch against OrangeFox's `bootable/recovery` (GPL-3.0-or-later like the files it touches): it makes the
recovery hold instead of rebooting when the GUI cannot start, time-limits the metadata decrypt, and
sends libbase log lines to `recovery.log`. It applies to commit `4f00a3d` of branch `fox_12.1`.

## Kernel (GPL-2.0): `prebuilt/Image.gz`, `prebuilt/dtb`, `prebuilt/dtbo.img`
Built from <https://github.com/PixelOS-Devices/android_kernel_xiaomi_sm6150>, branch
`sixteen-qpr2`, commit `f7d0768273eab39b52664efd2cfddcfdc9359e8e`
(Linux 4.14.356-openela-rc1-VantomKernel), `toco_defconfig`.
`kernel/toco_defconfig.resolved.config` is the resolved `.config` and `kernel/build_kernel.sh`
the exact build invocation. That source, plus those two files, is the corresponding source for
the kernel binary shipped here.

## Proprietary vendor binaries: `recovery/root/system/bin/*`, `recovery/root/vendor/lib64/**`
`qseecomd`, `android.hardware.keymaster@4.1-service-qti`, `android.hardware.gatekeeper@1.0-service-qti`
and their libraries are Qualcomm / Xiaomi proprietary binaries. They were taken, unmodified,
from <https://gitlab.com/NoPrincessHere/proprietary_vendor_xiaomi_sm6150-common> (branch `sixteen`),
which extracts them from the stock MIUI `V13.0.4.0.SFNMIXM` firmware of the Mi Note 10 Lite.
All rights remain with their owners. They are included only because decrypting `/data` in
recovery needs the same userspace the device's own vendor uses. Remove them if you do not
want to redistribute them; the recovery will then build but cannot decrypt.

## OrangeFox / TWRP
This tree builds against the OrangeFox `fox_12.1` build system (<https://gitlab.com/OrangeFox>)
and TWRP's minimal manifest. Neither is included here.
