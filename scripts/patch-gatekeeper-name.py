#!/usr/bin/env python3
# Copyright (C) 2026 AERA Recovery Project contributors
# SPDX-License-Identifier: Apache-2.0
"""
Point the MDFPP gatekeeper module's HMI.name at "gatekeeper".

The vendor module registers the HIDL instance named by the HMI.name string,
which the stock blob sets to "MDFPP Gatekeeper". Recovery looks up
android.hardware.gatekeeper@1.0::IGatekeeper/default, and the generic gatekeeper
service derives the instance name from HMI.name, so the stock value leaves the
service unreachable. The real MDFPP TA is unchanged: only the pointer to the
module name is rewritten, from "MDFPP Gatekeeper" to "gatekeeper".

The patch is a single 8-byte relative pointer in .data. Find both strings in
.rodata and the pointer that refers to the old one instead of hard-coding file
offsets, so a refreshed vendor blob with the same layout still patches. Running
it on an already patched blob is a no-op.

    scripts/patch-gatekeeper-name.py [--check] [path]

The default path is recovery/root/vendor/lib64/hw/gatekeeper.mdfpp.so.
--check reports the state without writing; exit 0 means patched.
"""

import argparse
import struct
import sys
from pathlib import Path

OLD_NAME = b"MDFPP Gatekeeper\0"
NEW_NAME = b"gatekeeper\0"

ELF_HEADER = struct.Struct("<16sHHIQQQIHHHHHH")
SECTION_HEADER = struct.Struct("<IIQQQQIIQQ")


def read_elf_sections(data):
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise SystemExit("not a little-endian ELF64 file")
    header = ELF_HEADER.unpack_from(data, 0)
    e_shoff = header[6]
    e_shentsize = header[11]
    e_shnum = header[12]
    e_shstrndx = header[13]
    if e_shentsize != SECTION_HEADER.size:
        raise SystemExit(f"unexpected section header size: {e_shentsize}")

    headers = [
        SECTION_HEADER.unpack_from(data, e_shoff + index * e_shentsize)
        for index in range(e_shnum)
    ]
    shstr = headers[e_shstrndx]
    names = data[shstr[4] : shstr[4] + shstr[5]]

    sections = {}
    for header in headers:
        name_start = header[0]
        name_end = names.find(b"\0", name_start)
        name = names[name_start:name_end].decode("ascii", "replace")
        sections[name] = {
            "addr": header[3],
            "offset": header[4],
            "size": header[5],
        }
    return sections


def rodata_offsets(data, needle):
    offsets = []
    start = 0
    while True:
        offset = data.find(needle, start)
        if offset < 0:
            return offsets
        offsets.append(offset)
        start = offset + 1


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    parser.add_argument(
        "path",
        nargs="?",
        default=str(
            Path(__file__).resolve().parent.parent
            / "recovery/root/vendor/lib64/hw/gatekeeper.mdfpp.so"
        ),
        help="gatekeeper.mdfpp.so to patch",
    )
    parser.add_argument(
        "--check", action="store_true", help="report the state without writing"
    )
    args = parser.parse_args()

    path = Path(args.path)
    data = bytearray(path.read_bytes())
    sections = read_elf_sections(data)

    try:
        rodata = sections[".rodata"]
        data_section = sections[".data"]
    except KeyError as missing:
        raise SystemExit(f"{path}: missing ELF section {missing}")

    old_offsets = rodata_offsets(data, OLD_NAME)
    if len(old_offsets) != 1:
        raise SystemExit(
            f"{path}: expected one {OLD_NAME!r} string, found {len(old_offsets)}"
        )
    old_offset = old_offsets[0]
    old_addr = rodata["addr"] + (old_offset - rodata["offset"])

    # "gatekeeper\0" also appears as the tail of "/vendor/gatekeeper\0"; the
    # standalone string starts at a NUL byte (or at the section start).
    candidates = []
    for offset in rodata_offsets(data, NEW_NAME):
        before = data[offset - 1] if offset > 0 else 0
        if before == 0:
            candidates.append(offset)
    if len(candidates) != 1:
        raise SystemExit(
            f"{path}: expected one standalone {NEW_NAME!r} string, "
            f"found {len(candidates)}"
        )
    new_addr = rodata["addr"] + (candidates[0] - rodata["offset"])

    expected = struct.pack("<Q", old_addr)
    replacement = struct.pack("<Q", new_addr)

    pointer_sections = [data_section, sections.get(".data.rel.ro")]
    pointers = []
    already = []
    for section in pointer_sections:
        if section is None:
            continue
        start = section["offset"]
        end = start + section["size"]
        for offset in range(start, end - 7, 8):
            value = data[offset : offset + 8]
            if value == expected:
                pointers.append(offset)
            elif value == replacement:
                already.append(offset)

    if not pointers:
        if already:
            print(f"{path.name}: already patched (HMI.name -> gatekeeper)")
            return 0
        raise SystemExit(
            f"{path}: no 8-byte pointer to {old_addr:#x} in .data/.data.rel.ro"
        )
    if len(pointers) > 1:
        raise SystemExit(
            f"{path}: expected one HMI.name pointer, found {len(pointers)}"
        )

    if args.check:
        print(f"{path.name}: needs patch (HMI.name -> gatekeeper)")
        return 1

    for offset in pointers:
        data[offset : offset + 8] = replacement
    path.write_bytes(data)
    print(
        f"{path.name}: patched HMI.name {old_addr:#x} -> {new_addr:#x} "
        f"at file offset {pointers[0]:#x}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
