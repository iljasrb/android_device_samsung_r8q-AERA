#!/usr/bin/env python3
# Copyright (C) 2026 AERA Recovery Project contributors
# SPDX-License-Identifier: Apache-2.0
"""
Check that the Adreno userspace closure is complete in the recovery ramdisk.

The vendor EGL/GLES driver, the gsl/llvm compiler libraries and the
gralloc/mapper stack are copied into recovery/root/vendor/lib64, but their
DT_NEEDED entries are split between the vendor directory and the platform
libraries the recovery image installs. A missing member shows up at runtime as
eglInitialize failing long before anything useful is logged, so resolve the
closure at build time instead.

Every NEEDED entry is looked up in vendor/lib64 (including egl/ and hw/) first,
then in system/lib64, matching the loader order for the vendor namespace.
Missing entries or an absent seed library fail the check.

    scripts/check-gpu-closure.py <recovery-root>

<recovery-root> is e.g. out/target/product/r8q/recovery/root.
"""

import argparse
import subprocess
import sys
from pathlib import Path

SEEDS = (
    ("vendor/lib64/egl", "libEGL_adreno.so"),
    ("vendor/lib64/egl", "libGLESv2_adreno.so"),
    ("vendor/lib64", "libgsl.so"),
    ("vendor/lib64", "libllvm-glnext.so"),
    ("vendor/lib64", "libadreno_utils.so"),
    ("vendor/lib64", "libgralloc.qti.so"),
    ("vendor/lib64", "libgralloccore.so"),
    ("vendor/lib64", "libgrallocutils.so"),
    ("vendor/lib64", "libgralloctypes.so"),
)

VENDOR_DIRS = ("vendor/lib64", "vendor/lib64/egl", "vendor/lib64/hw")
PLATFORM_DIR = "system/lib64"


def dynamic_info(path):
    """Return (soname or None, [needed...]) for an ELF file."""
    try:
        output = subprocess.run(
            ["readelf", "-dW", str(path)],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
    except FileNotFoundError:
        raise SystemExit("readelf not found; install binutils")
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"{path}: readelf failed: {error.stderr.strip()}")

    soname = None
    needed = []
    for line in output.splitlines():
        line = line.strip()
        if "(SONAME)" in line and "[" in line:
            soname = line[line.index("[") + 1 : line.rindex("]")]
        elif "(NEEDED)" in line and "[" in line:
            needed.append(line[line.index("[") + 1 : line.rindex("]")])
    return soname, needed


def index_libraries(root, relative_dirs):
    """Map SONAME (or file name) to the library path, in search order."""
    index = {}
    for relative in relative_dirs:
        directory = root / relative
        if not directory.is_dir():
            continue
        for path in sorted(directory.glob("*.so")):
            soname, _ = dynamic_info(path)
            index.setdefault(soname or path.name, path)
    return index


def resolve(name, vendor, platform):
    if name in vendor:
        return vendor[name], "vendor"
    if name in platform:
        return platform[name], "system"
    return None, None


def main():
    parser = argparse.ArgumentParser(
        description="check the Adreno userspace closure in a recovery root"
    )
    parser.add_argument("root", type=Path, help="recovery root (…/recovery/root)")
    args = parser.parse_args()

    root = args.root
    if not (root / "vendor/lib64").is_dir():
        raise SystemExit(f"{root}: no vendor/lib64")

    vendor = index_libraries(root, VENDOR_DIRS)
    platform = index_libraries(root, (PLATFORM_DIR,))

    missing_seeds = []
    queue = []
    for relative, name in SEEDS:
        if not (root / relative / name).is_file():
            missing_seeds.append(f"{relative}/{name}")
        else:
            queue.append((root / relative / name, "vendor"))

    problems = []
    seen = set()
    checked = 0
    while queue:
        path, namespace = queue.pop(0)
        key = (namespace, path.resolve())
        if key in seen:
            continue
        seen.add(key)
        checked += 1

        soname, needed = dynamic_info(path)
        for dependency in needed:
            resolved, found_in = resolve(dependency, vendor, platform)
            if resolved is None:
                problems.append(f"{path.relative_to(root)} needs {dependency}: not found")
                continue
            # A vendor library can pull in more vendor libraries; recurse into
            # both namespaces so a platform library with a vendor dependency is
            # not silently accepted.
            queue.append((resolved, found_in))

    for missing in missing_seeds:
        problems.append(f"missing seed library: {missing}")

    if problems:
        for problem in problems:
            print(f"ERROR: {problem}", file=sys.stderr)
        print(
            f"GPU closure incomplete: {len(problems)} problem(s) "
            f"across {checked} libraries",
            file=sys.stderr,
        )
        return 1

    print(
        f"GPU closure complete: {len(SEEDS)} seed libraries, "
        f"{checked} libraries resolved"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
