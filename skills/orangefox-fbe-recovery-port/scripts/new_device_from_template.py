#!/usr/bin/env python3
"""Generate an OrangeFox/TWRP device tree (with the /data decryption scaffolding) from the skill's template.

usage:
  new_device_from_template.py --conf device.conf --out DIR [--template DIR] [--ueventd FILE] [--force]
  new_device_from_template.py --conf device.conf --print-config        # effective values, nothing written

device.conf is a plain KEY=VALUE file (assets/device.conf.template documents every key, assets/device.conf.example is a
complete real one). DIR becomes device/<OEM>/<DEVICE> of the OrangeFox tree.

Template language (files ending in .in are rendered, all other files are copied unchanged, keeping their mode):
  @@KEY@@                       replaced by the value of KEY (unknown key = error, so a typo cannot slip through)
  #@@if EXPR / #@@elif EXPR / #@@else / #@@endif       the directive must be the whole line
  #@@for NAME in EXPR / #@@endfor                        repeats the block for every item of a Python expression
EXPR is a Python expression over the config keys (all values are strings; missing keys are ''); helpers: yes(v) is true for
yes/true/1/on, has(name) is true when name is in the PARTITIONS list. A file name containing DEVICE or HARDWARE gets that
config value in its place (fox_DEVICE.mk.in -> fox_toco.mk). Directive lines never reach the output; 'TODO(port)' markers do:
the generator lists them at the end, and every one of them is a decision for a human (or for Claude with the facts at hand).
"""
import argparse
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_TEMPLATE = os.path.join(HERE, "..", "assets", "device-tree-template")

REQUIRED = ["DEVICE", "OEM", "BRAND", "MODEL", "PLATFORM", "KERNEL_CMDLINE", "KERNEL_PREBUILT",
            "RECOVERY_PARTITION_SIZE", "SCREEN_W", "SCREEN_H"]

DEFAULTS = {
    "MAINTAINER": "port", "YEAR": "2026", "HARDWARE": "qcom", "QCOM": "yes", "AB": "no",
    "ARCH_VARIANT": "armv8-a", "CPU_VARIANT_RUNTIME": "generic", "GPU": "",
    "BOOT_HEADER_VERSION": "2", "PAGESIZE": "4096", "KERNEL_BASE": "0x00000000", "KERNEL_OFFSET": "0x00008000",
    "RAMDISK_OFFSET": "0x01000000", "SECOND_OFFSET": "0x00f00000", "TAGS_OFFSET": "0x00000100",
    "DTB_OFFSET": "0x01f00000", "DTB": "", "DTBO": "", "ALT_KERNEL_PREBUILT": "",
    "PANIC_ZERO": "yes", "AVB": "yes", "DTBO_PARTITION_SIZE": "", "CACHE_PARTITION_SIZE": "",
    "DYNAMIC_PARTITIONS": "no", "SUPER_SIZE": "", "SUPER_GROUP": "dynamic_partitions", "SUPER_GROUP_SIZE": "",
    "SUPER_PARTITION_LIST": "system system_ext product vendor odm", "BOARD_ROOT_EXTRA_FOLDERS": "",
    "USES_METADATA_PARTITION": "yes", "USERDATA_FS": "f2fs", "USE_EROFS": "yes", "F2FS_COMPRESSION": "no",
    "EXCLUDE_MTP": "yes", "CRYPTO_MODE": "none", "DATA_MNT_FLAGS": "", "DATA_FS_MGR_FLAGS": "", "DATA_TWRP_FLAGS": "",
    "KEYMASTER_VERSIONS": "4.1", "GATEKEEPER_VERSION": "1.0", "WEAVER": "no",
    "VINTF_TARGET_LEVEL": "5", "VINTF_SEPOLICY": "30.0",
    "MOUNT_FIRMWARE": "no", "FIRMWARE_PARTITION": "modem", "USB_CONTROLLER": "",
    "USB_VID": "0x18d1", "USB_PID": "0xd001", "USB_PID_MTP_ADB": "", "USB_OTG_DEVICE": "",
    "TW_THEME": "portrait_hdpi", "PIXEL_FORMAT": "RGBX_8888", "SHIPPING_API_LEVEL": "30",
    "BRIGHTNESS_PATH": "", "MAX_BRIGHTNESS": "255", "DEFAULT_BRIGHTNESS": "128", "INPUT_BLACKLIST": "",
    "NO_SCREEN_BLANK": "yes", "FRAMERATE": "60", "OF_STATUS_H": "100", "OF_STATUS_INDENT": "48", "HIDE_NOTCH": "no",
    "BLACKBOX": "yes", "PARTITIONS": "boot recovery cache metadata userdata misc",
}


def yes(v):
    return str(v).strip().lower() in ("yes", "true", "1", "on", "y")


class Ctx(dict):
    """Config values. An unknown UPPER_CASE name reads as '' (optional keys); anything else is looked up in the
    expression globals (yes, has), so a lower-case helper is never shadowed by an empty string."""
    def __missing__(self, key):
        if key.upper() == key:
            return ""
        raise KeyError(key)


def parse_conf(path):
    cfg = {}
    for n, raw in enumerate(open(path, encoding="utf-8"), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            sys.exit("%s:%d: expected KEY=VALUE, got: %s" % (path, n, line))
        k, v = line.split("=", 1)
        k, v = k.strip(), v.strip()
        if v[:1] in ("\"", "'"):  # quoted value, possibly followed by a comment
            end = v.find(v[0], 1)
            v = v[1:end] if end > 0 else v[1:]
        elif v.startswith("#"):
            v = ""
        elif " #" in v:  # trailing comment on an unquoted value
            v = v.split(" #", 1)[0].rstrip()
        cfg[k] = v
    return cfg


def complete(cfg):
    missing = [k for k in REQUIRED if not cfg.get(k)]
    if missing:
        sys.exit("device.conf is missing required keys: " + ", ".join(missing))
    c = Ctx(DEFAULTS)
    for k, v in cfg.items():
        if v != "" or k not in DEFAULTS:  # an empty value in device.conf means "use the default"
            c[k] = v
    if not c.get("MANUFACTURER"):
        c["MANUFACTURER"] = c["BRAND"]
    if not c.get("BOOTLOADER_BOARD_NAME"):
        c["BOOTLOADER_BOARD_NAME"] = c["PLATFORM"]
    if not c.get("BOOT_PARTITION_SIZE"):
        c["BOOT_PARTITION_SIZE"] = c["RECOVERY_PARTITION_SIZE"]
    if not c.get("KERNEL_IMAGE_NAME"):
        c["KERNEL_IMAGE_NAME"] = "Image.gz" if c["KERNEL_PREBUILT"].endswith(".gz") else "Image"
    if not c.get("FLASH_BLOCK_SIZE"):
        c["FLASH_BLOCK_SIZE"] = str(int(c["PAGESIZE"], 0) * 64)
    if not c.get("USB_PID_MTP_ADB"):
        c["USB_PID_MTP_ADB"] = c["USB_PID"]
    c["SUPER_GROUP_UPPER"] = c["SUPER_GROUP"].upper()
    if yes(c["DYNAMIC_PARTITIONS"]):
        if not c["SUPER_SIZE"]:
            sys.exit("DYNAMIC_PARTITIONS=yes needs SUPER_SIZE (bytes; adb shell blockdev --getsize64 /dev/block/by-name/super)")
        if not c["SUPER_GROUP_SIZE"]:
            c["SUPER_GROUP_SIZE"] = str(int(c["SUPER_SIZE"]) - 4194304)  # 4 MiB metadata overhead
    mode = c["CRYPTO_MODE"]
    if mode not in ("none", "fde", "fbe", "fbe_metadata", "fbe_metadata_wrapped"):
        sys.exit("CRYPTO_MODE must be one of none, fde, fbe, fbe_metadata, fbe_metadata_wrapped (got %r)" % mode)
    if mode != "none":
        for k in ("DATA_MNT_FLAGS", "DATA_FS_MGR_FLAGS", "DATA_TWRP_FLAGS"):
            if not c[k]:
                sys.exit("CRYPTO_MODE=%s needs %s, copied from the /data line of the ROM's fstab" % (mode, k))
        if not yes(c["QCOM"]):
            print("warning: this template only knows the Qualcomm decryption stack (QCOM=yes); for other SoCs the crypto "
                  "block is generated but you must add the TEE daemon / HAL services yourself "
                  "(see recovery-fbe-decryption/references/other-socs.md)", file=sys.stderr)
    if not c.get("FSCRYPT_POLICY"):
        c["FSCRYPT_POLICY"] = "2" if re.search(r"(^|[:+,])v2([:+,]|$)", c["DATA_TWRP_FLAGS"]) else "1"
    c["PARTS"] = set(c["PARTITIONS"].split())
    return c


# ---------------------------------------------------------------- template engine
DIRECTIVE = re.compile(r"^\s*#@@(if|elif|else|endif|for|endfor)\b(.*)$")
PLACEHOLDER = re.compile(r"@@([A-Za-z_][A-Za-z0-9_]*)@@")


def parse(lines):
    """Turn the lines into a tree: ('text', line) | ('if', [(expr, body), ...]) | ('for', var, expr, body)."""
    pos = 0

    def block(stop):
        nonlocal pos
        out = []
        while pos < len(lines):
            line = lines[pos]
            m = DIRECTIVE.match(line)
            if not m:
                out.append(("text", line))
                pos += 1
                continue
            kind, rest = m.group(1), m.group(2).strip()
            if kind in stop:
                return out, kind, rest
            pos += 1
            if kind == "if":
                branches, expr = [], rest
                while True:
                    body, end, endrest = block(("elif", "else", "endif"))
                    branches.append((expr, body))
                    pos += 1
                    if end == "endif":
                        break
                    expr = "True" if end == "else" else endrest
                out.append(("if", branches))
            elif kind == "for":
                var, _, expr = rest.partition(" in ")
                body, end, _r = block(("endfor",))
                pos += 1
                out.append(("for", var.strip(), expr.strip(), body))
            else:
                raise SystemExit("template error: unexpected #@@%s at line %d" % (kind, pos + 1))
        if stop:
            raise SystemExit("template error: missing #@@%s" % "/".join(stop))
        return out, None, None

    tree, _, _ = block(())
    return tree


def render(tree, ctx, out, where):
    env = {"__builtins__": {}, "yes": yes, "has": lambda n: n in ctx["PARTS"]}
    for node in tree:
        if node[0] == "text":
            line = node[1]

            def sub(m):
                key = m.group(1)
                if key not in ctx:
                    raise SystemExit("%s: unknown placeholder @@%s@@" % (where, key))
                return str(ctx[key])
            out.append(PLACEHOLDER.sub(sub, line))
        elif node[0] == "if":
            for expr, body in node[1]:
                if eval(expr, env, ctx):
                    render(body, ctx, out, where)
                    break
        else:
            _k, var, expr, body = node
            for item in eval(expr, env, ctx):
                inner = Ctx(ctx)
                inner[var] = item
                render(body, inner, out, where)


def render_text(text, ctx, where):
    tree = parse(text.splitlines(keepends=True))
    out = []
    render(tree, ctx, out, where)
    return "".join(out)


def dest_name(name, ctx):
    if name.endswith(".in"):
        name = name[:-3]
    return name.replace("DEVICE", ctx["DEVICE"]).replace("HARDWARE", ctx["HARDWARE"])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--conf", required=True)
    ap.add_argument("--out")
    ap.add_argument("--template", default=DEFAULT_TEMPLATE)
    ap.add_argument("--ueventd", help="a ueventd.rc of a reference tree of the same SoC, copied to recovery/root/ueventd.<HARDWARE>.rc")
    ap.add_argument("--force", action="store_true", help="write into a directory that already has files")
    ap.add_argument("--print-config", action="store_true")
    a = ap.parse_args()

    ctx = complete(parse_conf(a.conf))
    if a.print_config:
        for k in sorted(ctx):
            if k != "PARTS":
                print("%s=%s" % (k, ctx[k]))
        return 0
    if not a.out:
        ap.error("--out is required")
    if os.path.exists(a.out) and os.listdir(a.out) and not a.force:
        sys.exit("%s is not empty (use --force to write into it)" % a.out)

    written, todos = [], []
    for dp, dn, fn in os.walk(a.template):
        dn.sort()
        rel_dir = os.path.relpath(dp, a.template)
        for f in sorted(fn):
            src = os.path.join(dp, f)
            rel = f if rel_dir == "." else os.path.join(rel_dir, f)
            out_rel = os.path.join(os.path.dirname(rel), dest_name(f, ctx))
            dst = os.path.join(a.out, out_rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if f.endswith(".in"):
                text = render_text(open(src, encoding="utf-8").read(), ctx, rel)
                with open(dst, "w", encoding="utf-8") as fh:
                    fh.write(text)
                shutil.copymode(src, dst)
                for n, line in enumerate(text.splitlines(), 1):
                    if "TODO(port):" in line:
                        todos.append("%s:%d: %s" % (out_rel, n, line.strip()))
            else:
                shutil.copy2(src, dst)
            written.append(out_rel)

    if a.ueventd:
        dst = os.path.join(a.out, "recovery", "root", "ueventd.%s.rc" % ctx["HARDWARE"])
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(a.ueventd, dst)
        written.append(os.path.relpath(dst, a.out))
    else:
        todos.append("recovery/root/ueventd.%s.rc: not generated. TODO(port): copy the ueventd.rc of a reference tree of the same "
                     "SoC (it grants /dev/qseecom, /dev/ion, /dev/sg* and the display/touch nodes to the right users), or pass --ueventd FILE" % ctx["HARDWARE"])

    for key in ("KERNEL_PREBUILT", "DTB", "DTBO"):
        if ctx[key] and not os.path.exists(os.path.join(a.out, ctx[key])):
            todos.append("%s: TODO(port): %s is set to %s but that file is not in the tree yet: copy it there (the ROM's boot.img "
                         "gives the kernel and the dtb: scripts/unpack_and_inspect_boot.sh)" % (ctx[key], key, ctx[key]))
    # keep the configuration with the tree: it is the record of what the generated files were made from
    os.makedirs(os.path.join(a.out, "port"), exist_ok=True)
    shutil.copy2(a.conf, os.path.join(a.out, "port", "device.conf"))
    for sub in ("prebuilt",):
        os.makedirs(os.path.join(a.out, sub), exist_ok=True)

    print("wrote %d files into %s" % (len(written), a.out))
    for w in sorted(written):
        print("  ", w)
    print("\n%d item(s) need a human decision:" % len(todos))
    for t in todos:
        print("  TODO", t)
    print("\nnext: put the kernel / dtb / dtbo into prebuilt/ (see KERNEL_PREBUILT, DTB, DTBO in port/device.conf), add the vendor blobs of "
          "the decryption stack under recovery/root (collect_decrypt_blobs.py in the recovery-fbe-decryption skill), apply "
          "patches/0001-startup-hardening.patch to bootable/recovery, then sync the tree into the OrangeFox tree and build "
          "both variants (recovery-build-environment skill).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
