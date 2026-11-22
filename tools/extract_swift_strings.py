#!/usr/bin/env python3
"""Extract Swift string literals referenced in decompiled C output.

Swift string literals appear as 0x80000001XXXXXXXX (small-string pointer tag) plus
a length on the following register. We resolve each address against the binary's
__TEXT segment and print the C string at that offset.
"""
import re
import sys
import struct

BIN = r"C:\Users\xaehd\WorkBuddy\2026-11-22-00-22-51\carwithin-analysis\ipa\Payload\TDSCarKit.app\TDSCarKit"


def load_binary():
    data = open(BIN, "rb").read()
    # parse mach-o 64 header
    magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags, res = struct.unpack("<IiiIIIII", data[:32])
    off = 32
    segs = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", data[off:off + 8])
        if cmd == 0x19:  # LC_SEGMENT_64
            segname = data[off + 8:off + 24].rstrip(b"\0").decode()
            vmaddr, vmsize = struct.unpack("<QQ", data[off + 24:off + 40])
            fileoff, filesize = struct.unpack("<QQ", data[off + 40:off + 56])
            segs.append((segname, vmaddr, vmsize, fileoff, filesize))
        off += cmdsize
    return data, segs


def va_to_off(segs, va):
    for name, vmaddr, vmsize, fileoff, filesize in segs:
        if vmaddr <= va < vmaddr + filesize:
            return fileoff + (va - vmaddr)
    return None


def cstring_at(data, off, maxlen=300):
    end = off
    while end < len(data) and data[end] != 0 and end - off < maxlen:
        end += 1
    raw = data[off:end]
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("latin-1")


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "cp-core.c"
    data, segs = load_binary()
    text = open(src, encoding="utf-8", errors="replace").read()
    # 0x80000001XXXXXXXX pattern (arm64e tagged pointer for strings)
    pat = re.compile(r"0x80000001([0-9a-fA-F]{8})")
    seen = {}
    for m in pat.finditer(text):
        va = int("1" + m.group(1), 16)
        if va in seen:
            continue
        off = va_to_off(segs, va)
        if off is None:
            continue
        s = cstring_at(data, off)
        seen[va] = s
    for va in sorted(seen):
        s = seen[va]
        printable = all(31 < ord(c) < 127 or c in "\n\t" or ord(c) > 127 for c in s)
        if s and printable:
            print("0x%X\t%s" % (va, s))


if __name__ == "__main__":
    main()