#!/usr/bin/env python3
"""Replace a Hackage tarball's .cabal file with the pinned revised revision.

Usage: patch-wasm-cabal.py NAME VERSION TARBALL REVISED_CABAL OUTPUT

Hackage package tarballs contain the original .cabal file; the secure Hackage
repository additionally applies the latest published revision when cabal sets a
package up. The Nix WebAssembly build uses an old-format local repository,
which has no revision concept, so without this step dependency packages would
compile with the original (sometimes different) build configuration and the
bundle would not match a developer build. The revised file is the one vendored
under nix/wasm-cabal/; the output tarball is deterministic for the same input.
"""

import gzip
import io
import os
import sys
import tarfile

FIXED_MTIME = 0


def replace_cabal(tar_path, name, revised, output_path):
    with tarfile.open(tar_path, "r:gz") as source:
        members = source.getmembers()
        replaced = False
        payload = []
        for member in members:
            data = source.extractfile(member).read() if member.isfile() else b""
            if member.isfile() and os.path.basename(member.name) == f"{name}.cabal":
                data = revised
                replaced = True
            payload.append((member, data))
    if not replaced:
        sys.exit(f"patch-wasm-cabal: {name}.cabal not found in {tar_path}")

    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as target:
        for member, data in payload:
            if not member.isfile():
                continue
            info = tarfile.TarInfo(member.name)
            info.size = len(data)
            info.mtime = FIXED_MTIME
            info.uid = 0
            info.gid = 0
            info.uname = ""
            info.gname = ""
            info.mode = member.mode
            target.addfile(info, io.BytesIO(data))

    with open(output_path, "wb") as output:
        output.write(gzip.compress(raw.getvalue(), compresslevel=9, mtime=0))


def main():
    if len(sys.argv) != 6:
        sys.exit("usage: patch-wasm-cabal.py NAME VERSION TARBALL REVISED_CABAL OUTPUT")
    name, version, tarball, revised_path, output_path = sys.argv[1:6]
    with open(revised_path, "rb") as revised_file:
        revised = revised_file.read()
    replace_cabal(tarball, name, revised, output_path)


if __name__ == "__main__":
    main()
