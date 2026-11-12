#!/usr/bin/env python3
"""Export a pinned, selected Git reference as read-only sandbox input, never a live checkout."""
import argparse
import hashlib
import io
import json
import subprocess
import tarfile
from pathlib import Path, PurePosixPath


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--ref", required=True)
    parser.add_argument("--path", action="append", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    commit = subprocess.check_output(["git", "-C", str(args.repo), "rev-parse", args.ref + "^{commit}"], text=True).strip()
    data = subprocess.check_output(["git", "-C", str(args.repo), "archive", "--format=tar", commit, "--", *args.path])
    if len(data) > 8 * 1024 * 1024:
        raise ValueError("Reference archive exceeds limit")
    files = {}
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        for item in archive:
            path = PurePosixPath(item.name)
            if item.isdir():
                continue
            if not item.isfile() or path.is_absolute() or ".." in path.parts:
                raise ValueError("Reference contains non-regular or unsafe entries")
            files[path.as_posix()] = archive.extractfile(item).read()
    manifest = {"commit": commit, "paths": args.path,
                "files": {name: hashlib.sha256(content).hexdigest() for name, content in files.items()}}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.output.exists():
        previous = json.loads((args.output / "REFERENCE.json").read_text())
        if previous != manifest or any((args.output / name).read_bytes() != content for name, content in files.items()):
            raise ValueError("Existing reference differs; refusing overwrite")
    else:
        args.output.mkdir(mode=0o700)
        for name, content in files.items():
            path = args.output / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
            path.chmod(0o444)
        (args.output / "REFERENCE.json").write_text(json.dumps(manifest, indent=2))
        (args.output / "REFERENCE.json").chmod(0o444)
    print(str(args.output), "commit", commit, "regular files", len(files))


if __name__ == "__main__":
    main()
