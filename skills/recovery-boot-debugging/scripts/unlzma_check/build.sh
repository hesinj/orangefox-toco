#!/usr/bin/env bash
# Build the harness that runs the Linux kernel's own LZMA decoder (lib/decompress_unlzma.c) in user space.
#   ./build.sh                       -> ./harness
#   ./harness ramdisk.lzma [reference]    decodes with the kernel's code; with a reference file it also says IDENTICAL or DIFFERENT
# If the kernel decoder rejects a stream that the host's lzma/xz decodes, the kernel would not unpack that ramdisk either (it hangs the boot or
# panics with "junk in compressed archive" / "Initramfs unpacking failed"). Create the stream like the OrangeFox build does:  lzma -9 < ramdisk.cpio > ramdisk.lzma
set -e
cd "$(dirname "$0")"
${CC:-gcc} -O2 -I shim -o harness harness.c
echo built: $(pwd)/harness
