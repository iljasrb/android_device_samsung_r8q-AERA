#!/usr/bin/env python3
"""Fix the microSD tray's detect line in the recovery's device trees.

The vendor's tree for the r8q names the tray's detect line active high and
leaves it without a pull, while the board pulls the line up and grounds it as
a card goes in. Read high, the kernel says the tray is empty for as long as
the phone runs and never looks at the card. Both are words of the tree, so
this patch puts them right in the recovery's own copies, leaving the
installed system's alone.

This is a Python port of Skyward's crates/skyward-pack/src/tree.rs
(detect_active_low and detect_pull_up).

Usage:
    scripts/fix-sdcard-dtb.py [--check] DTB DTBO

DTB is the base device tree (prebuilt/dtb), DTBO the overlay image
(prebuilt/dtbo.img). The pin number defaults to 77 (r8q's detect line).
"""

import argparse
import struct
import sys

OVERLAY_MAGIC = 0xD7B7AB1E
FDT_MAGIC = 0xD00DFEED

DETECT = "cd-gpios"
PULL = ("bias-disable", "bias-pull-up")
PINS = "pins"
GROUP = "config"
ACTIVE_LOW = 1


def be32(blob, at):
    return struct.unpack_from(">I", blob, at)[0]


def put32(blob, at, value):
    struct.pack_into(">I", blob, at, value)


class Tree:
    def __init__(self, fdt):
        if be32(fdt, 0) != FDT_MAGIC:
            raise ValueError("not a flattened device tree")
        self.fdt = bytes(fdt)
        self.strings_at = be32(fdt, 12)
        self.strings_len = be32(fdt, 32)
        self.struct_at = be32(fdt, 8)
        self.struct_len = be32(fdt, 36)

    def strings(self):
        return self.fdt[self.strings_at:self.strings_at + self.strings_len]

    def word_at(self, word):
        strings = self.strings()
        at = 0
        while at < len(strings):
            end = strings.index(0, at)
            if strings[at:end] == word.encode():
                return at
            at = end + 1
        raise ValueError(f"the tree says no {word!r}")

    def nodes(self):
        strings = self.strings()
        at = self.struct_at
        end = at + self.struct_len
        path = []
        out = []
        while at + 4 <= end:
            token = be32(self.fdt, at)
            at += 4
            if token == 1:  # FDT_BEGIN_NODE
                name_end = self.fdt.index(0, at)
                path.append(bytes(self.fdt[at:name_end]).decode("utf-8", "replace"))
                out.append((list(path), []))
                at = (name_end + 1 + 3) & ~3
            elif token == 2:  # FDT_END_NODE
                path.pop()
            elif token == 3:  # FDT_PROP
                length = be32(self.fdt, at)
                name_at = at + 4
                at += 8
                value_at = at
                name_off = be32(self.fdt, name_at)
                name = bytes(strings[name_off:strings.index(0, name_off)]).decode("utf-8", "replace")
                value = bytes(self.fdt[value_at:value_at + length])
                at = (value_at + length + 3) & ~3
                if out:
                    out[-1][1].append({
                        "name_at": name_at,
                        "value_at": value_at,
                        "name": name,
                        "value": value,
                    })
            elif token == 4:  # FDT_NOP
                pass
            elif token == 9:  # FDT_END
                break
            else:
                raise ValueError(f"unknown token {token:#x} in the tree's structure")
        return out


def overlays(dtbo):
    if be32(dtbo, 0) != OVERLAY_MAGIC:
        raise ValueError("not a device tree overlay image")
    entry_size = be32(dtbo, 12)
    count = be32(dtbo, 16)
    entries_at = be32(dtbo, 20)
    if entry_size < 8 or count == 0:
        raise ValueError("the overlay image holds no entries")
    out = []
    for k in range(count):
        at = entries_at + k * entry_size
        size = be32(dtbo, at)
        offset = be32(dtbo, at + 4)
        if size == 0:
            continue
        if offset + size > len(dtbo):
            raise ValueError(f"the overlay at {offset} runs past the image")
        out.append((offset, size))
    return out


def detect_active_low(dtbo, pin):
    out = bytearray(dtbo)
    changed = 0
    wanted = struct.pack(">I", pin)
    for at, size in overlays(out):
        tree = Tree(memoryview(out)[at:at + size])
        for _, props in tree.nodes():
            for prop in props:
                if prop["name"] != DETECT or len(prop["value"]) != 12:
                    continue
                if prop["value"][4:8] != wanted:
                    continue
                flags = prop["value_at"] + 8
                if be32(out, at + flags) != ACTIVE_LOW:
                    put32(out, at + flags, ACTIVE_LOW)
                    changed += 1
    return bytes(out), changed


def trees(dtb):
    out = []
    at = 0
    while at + 8 <= len(dtb):
        try:
            magic = be32(dtb, at)
            size = be32(dtb, at + 4)
        except struct.error:
            break
        if magic != FDT_MAGIC or size < 40 or at + size > len(dtb):
            break
        out.append((at, size))
        at += (size + 3) & ~3
    return out


def detect_pull_up(dtb, pin):
    out = bytearray(dtb)
    changed = 0
    named = f"gpio{pin}"
    for at, size in trees(out):
        tree = Tree(memoryview(out)[at:at + size])
        pull_up = tree.word_at(PULL[1])
        for path, props in tree.nodes():
            if not path or path[-1] != GROUP:
                continue
            holds_pin = any(
                p["name"] == PINS and p["value"].rstrip(b"\0").decode("utf-8", "replace") == named
                for p in props
            )
            floating = any(p["name"] == PULL[0] for p in props)
            if not holds_pin or not floating:
                continue
            for prop in props:
                if prop["name"] != PULL[0]:
                    continue
                put32(out, at + prop["name_at"], pull_up)
                changed += 1
    return bytes(out), changed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="report what would change, write nothing")
    parser.add_argument("--pin", type=int, default=77, help="detect line (default: 77)")
    parser.add_argument("dtb", help="base device tree (prebuilt/dtb)")
    parser.add_argument("dtbo", help="overlay image (prebuilt/dtbo.img)")
    args = parser.parse_args()

    with open(args.dtb, "rb") as f:
        dtb = f.read()
    with open(args.dtbo, "rb") as f:
        dtbo = f.read()

    new_dtb, dtb_changed = detect_pull_up(dtb, args.pin)
    new_dtbo, dtbo_changed = detect_active_low(dtbo, args.pin)

    print(f"{args.dtb}: {dtb_changed} pull-up change(s)")
    print(f"{args.dtbo}: {dtbo_changed} active-low change(s)")

    if args.check:
        return 0 if dtb_changed or dtbo_changed else 0

    if dtb_changed:
        with open(args.dtb, "wb") as f:
            f.write(new_dtb)
    if dtbo_changed:
        with open(args.dtbo, "wb") as f:
            f.write(new_dtbo)
    return 0


if __name__ == "__main__":
    sys.exit(main())
