# unlzma_check: does the kernel's own LZMA decoder accept this ramdisk?

`unlzma_kernel.c` is `lib/decompress_unlzma.c` of the Linux 4.14 kernel (PixelOS-Devices/android_kernel_xiaomi_sm6150), unmodified, LGPL-2.1-or-later (see its header).
`harness.c` and `shim/` are small glue files so that it compiles in user space. Use it before shipping a recovery with an LZMA ramdisk
(`FOX_LZMA_RAMDISK=true`): the kernel supports only the decompressors that were compiled in (`CONFIG_RD_GZIP/BZIP2/LZMA/XZ/LZO/LZ4/ZSTD`; the reference kernel had gzip, bzip2, lz4 and lzma, **no xz**),
and an "xz" stream with an `.lzma` name is the classic way to brick a boot test.

```
./build.sh
unlzma < ramdisk.lzma > /tmp/ref.cpio           # host reference (or: lzma -dc)
./harness ramdisk.lzma /tmp/ref.cpio             # kernel decoder vs reference
```
Expected: `unlzma returned 0, produced N bytes, consumed X of X input bytes` and `reference N bytes: IDENTICAL`.
Verified on the reference port: the 18.2 MB LZMA ramdisk of the full image decoded to 74,540,544 bytes with the kernel's code.
