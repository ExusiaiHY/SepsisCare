#!/usr/bin/env python3
"""Restore and verify the original ZIP from the GitHub Release parts."""

import hashlib
import json
from pathlib import Path
import sys


ARCHIVE_NAME = "SepsisCare_Final_Submission_20260612.zip"
ARCHIVE_SIZE = 1492554011
ARCHIVE_SHA256 = "94cb4aa37efa3c7e97fc742df2f80d1280260bd09c82fd0fa3bf66066825dd36"
PART_COUNT = 23


def digest_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def restore(directory):
    directory = directory.expanduser().resolve()
    output = directory / ARCHIVE_NAME
    if output.exists():
        if output.stat().st_size == ARCHIVE_SIZE and digest_file(output) == ARCHIVE_SHA256:
            print(f"Already restored and verified: {output}")
            return
        raise ValueError(f"Refusing to overwrite an existing file: {output}")

    manifest = json.loads((directory / "ARCHIVE_PARTS.json").read_text(encoding="utf-8"))
    expected_names = [f"{ARCHIVE_NAME}.{number:03d}" for number in range(1, PART_COUNT + 1)]
    if [part["name"] for part in manifest["parts"]] != expected_names:
        raise ValueError("The part manifest does not match this submission.")
    missing = [name for name in expected_names if not (directory / name).is_file()]
    if missing:
        raise ValueError("Missing release parts: " + ", ".join(missing))

    temporary = directory / (ARCHIVE_NAME + ".partial")
    archive_hash = hashlib.sha256()
    total_size = 0
    # Exclusive creation preserves any partial file from an earlier interrupted run.
    with temporary.open("xb") as destination:
        try:
            for part in manifest["parts"]:
                part_hash = hashlib.sha256()
                part_size = 0
                with (directory / part["name"]).open("rb") as source:
                    for chunk in iter(lambda: source.read(8 * 1024 * 1024), b""):
                        destination.write(chunk)
                        part_hash.update(chunk)
                        archive_hash.update(chunk)
                        part_size += len(chunk)
                if part_size != part["size"] or part_hash.hexdigest() != part["sha256"]:
                    raise ValueError("Part checksum failed: " + part["name"])
                total_size += part_size
            if total_size != ARCHIVE_SIZE or archive_hash.hexdigest() != ARCHIVE_SHA256:
                raise ValueError("Restored ZIP checksum failed.")
        except BaseException:
            destination.close()
            temporary.unlink(missing_ok=True)
            raise
    temporary.rename(output)
    print(f"Restored and SHA-256 verified: {output}")


if __name__ == "__main__":
    if len(sys.argv) > 2:
        raise SystemExit("Usage: python3 restore_archive.py [directory-containing-release-assets]")
    try:
        restore(Path(sys.argv[1]) if len(sys.argv) == 2 else Path(__file__).resolve().parent)
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise SystemExit(str(error)) from error
