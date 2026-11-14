#!/usr/bin/env python3
"""Build the Hackage index tar for the pinned WebAssembly dependency set.

The Nix WebAssembly build cannot run `cabal update` against Hackage (it must be
offline and reproducible), and the current Hackage index is not immutable. This
script writes the small old-format index cabal needs from the pinned package
metadata vendored under nix/wasm-cabal/:

    build-wasm-index.py MANIFEST CABAL_DIR OUTPUT

MANIFEST has one "<name> <version>" line per dependency (generated from
nix/wasm-hackage.nix). CABAL_DIR holds the package's latest published Hackage
revision as "<name>-<version>.cabal" (that is the metadata the solver uses; the
tarball only supplies the source). Entries are written in the index's
"<name>/<version>/<name>.cabal" layout in sorted order, with one fixed mtime
before the plan's index-state, so the same inputs produce the same tar.
"""

import gzip
import io
import os
import sys
import tarfile

# 2026-11-06T16:26:54Z, one day before cabal.project.wasm's
# index-state pin, so every vendored entry is inside the requested state.
INDEX_MTIME = 1793982414


def read_manifest(path):
    entries = []
    with open(path, encoding="utf-8") as manifest:
        for line in manifest:
            line = line.strip()
            if not line:
                continue
            name, version = line.split()
            entries.append((name, version))
    entries.sort()
    return entries


def main():
    if len(sys.argv) != 4:
        sys.exit("usage: build-wasm-index.py MANIFEST CABAL_DIR OUTPUT")
    manifest_path, cabal_dir, output_path = sys.argv[1:4]
    entries = read_manifest(manifest_path)

    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for name, version in entries:
            cabal_path = os.path.join(cabal_dir, f"{name}-{version}.cabal")
            with open(cabal_path, "rb") as cabal_file:
                data = cabal_file.read()
            info = tarfile.TarInfo(f"{name}/{version}/{name}.cabal")
            info.size = len(data)
            info.mtime = INDEX_MTIME
            info.uid = 0
            info.gid = 0
            info.uname = ""
            info.gname = ""
            info.mode = 0o644
            tar.addfile(info, io.BytesIO(data))

    with open(output_path, "wb") as output:
        output.write(gzip.compress(raw.getvalue(), compresslevel=9, mtime=0))


if __name__ == "__main__":
    main()
