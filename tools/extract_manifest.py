"""Static Mach-O inventory for the 1:1 replica.

REA needs a working provider (Ghidra/Hopper/IDA/Kuna) to decompile; this script
does not decompile. It produces a stable inventory that we can diff against REA
output later, and that already answers "which Swift types exist".

Usage:
    python tools/extract_manifest.py path/to/TDSCarKit -o analysis/manifest.json
"""
from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path

MACHO64 = 0xFEEDFACF
LC_SYMTAB = 0x2
LC_SEGMENT_64 = 0x19


def read_symbols(data: bytes, offset: int):
    """Yield (name, n_type, n_sect, n_value) from LC_SYMTAB."""
    cmd, size, symoff, nsyms, stroff, strsize = struct.unpack_from("<IIIIII", data, offset)
    strings = data[stroff:stroff + strsize]
    out = []
    for i in range(nsyms):
        base = symoff + i * 16
        if base + 16 > len(data):
            break
        n_strx, n_type, n_sect, _n_desc, n_value = struct.unpack_from("<IBBHQ", data, base)
        end = strings.find(b"\0", n_strx)
        name = strings[n_strx:end if end >= 0 else None].decode("utf-8", "replace")
        if name:
            out.append((name, n_type, n_sect, n_value))
    return out


def read_cstrings(data: bytes):
    found = []
    i, n = 0, len(data)
    cur = bytearray()
    while i < n:
        b = data[i]
        if 32 <= b < 127 or b >= 0x80:
            cur.append(b)
            i += 1
            continue
        if len(cur) >= 4:
            try:
                text = cur.decode("utf-8")
            except UnicodeDecodeError:
                text = ""
            if text and any("\u4e00" <= ch <= "\u9fff" for ch in text):
                found.append(text)
        cur = bytearray()
        i += 1
    # de-duplicate but keep order
    seen = set()
    return [s for s in found if not (s in seen or seen.add(s))]


def _read_identifier(text: str, index: int) -> tuple[str | None, int]:
    """Swift mangling: identifiers are length-prefixed, e.g. `9TDSCarKit`."""
    start = index
    while index < len(text) and text[index].isdigit():
        index += 1
    if index == start:
        return None, index
    length = int(text[start:index])
    name = text[index:index + length]
    if len(name) != length or not name or not name[0].isalpha():
        return None, index + length
    return name, index + length


def swift_type_of(symbol: str) -> tuple[str, str] | None:
    """Classify a Swift symbol into (module, nominal type).

    Handles nesting such as `_$s9TDSCarKit13NinebotOutput...Session`, where the
    outer type is what we want for a type inventory.
    """
    if not symbol.startswith("_$s"):
        return None
    body = symbol[3:]
    module, index = _read_identifier(body, 0)
    if not module:
        return None
    parts: list[str] = []
    while len(parts) < 3:
        name, index = _read_identifier(body, index)
        if not name:
            break
        parts.append(name)
    if not parts:
        return None
    return module, ".".join(parts)


def build_manifest(path: Path) -> dict:
    data = path.read_bytes()
    if len(data) < 32:
        raise SystemExit("文件太小，不是 Mach-O")
    magic, cpu, _sub, filetype, ncmds, sizeofcmds, _flags, _res = struct.unpack_from("<IiiIIIII", data, 0)
    if magic != MACHO64:
        raise SystemExit(f"仅支持 64 位小端 Mach-O，magic=0x{magic:08x}")

    symbols = []
    offset = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        if cmd == LC_SYMTAB:
            symbols = read_symbols(data, offset)
        offset += cmdsize
        if offset > 32 + sizeofcmds:
            break

    types: dict[str, set[str]] = {}
    undefined_imports = set()
    for name, n_type, _n_sect, _value in symbols:
        if (n_type & 0x0E) == 0:          # N_UNDF: imported symbol
            undefined_imports.add(name)
            continue
        parsed = swift_type_of(name)
        if parsed:
            module, nominal = parsed
            types.setdefault(module, set()).add(nominal)

    strings = read_cstrings(data)

    return {
        "file": str(path),
        "size": len(data),
        "cpu": cpu,
        "filetype": filetype,
        "symbol_count": len(symbols),
        "import_count": len(undefined_imports),
        "swift_modules": {k: sorted(v) for k, v in sorted(types.items())},
        "ui_strings": strings,
        "imports_sample": sorted(undefined_imports)[:400],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary")
    parser.add_argument("-o", "--output", default="analysis/manifest.json")
    args = parser.parse_args()

    manifest = build_manifest(Path(args.binary))
    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"符号 {manifest['symbol_count']}，导入 {manifest['import_count']}，"
          f"中文串 {len(manifest['ui_strings'])}")
    for module, names in manifest["swift_modules"].items():
        print(f"  {module}: {len(names)} 个类型")
    print(f"已写入 {out}")


if __name__ == "__main__":
    main()
