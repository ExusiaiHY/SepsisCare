#!/usr/bin/env python3
"""Verify SepsisCare model artifact bundle integrity."""
from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import sys
import zipfile
from pathlib import Path
from pathlib import PurePosixPath
from typing import Any


MANIFEST_NAME = "MANIFEST.sha256"
SIGNATURE_NAME = "MANIFEST.sha256.hmac"


class ArtifactVerificationError(RuntimeError):
    pass


def normalize_manifest_path(name: str, line_number: int) -> str:
    normalized = name.strip().replace("\\", "/")
    parts = PurePosixPath(normalized).parts
    if (
        not normalized
        or normalized.startswith("/")
        or any(part == ".." for part in parts)
        or (parts and ":" in parts[0])
    ):
        raise ArtifactVerificationError(f"unsafe manifest path on line {line_number}")
    return normalized


def parse_manifest(manifest_text: str) -> list[tuple[str, str]]:
    entries: list[tuple[str, str]] = []
    for line_number, raw_line in enumerate(manifest_text.splitlines(), start=1):
        line = raw_line.strip()
        if not line:
            continue
        try:
            digest, name = line.split(None, 1)
        except ValueError as exc:
            raise ArtifactVerificationError(f"invalid manifest line {line_number}") from exc
        digest = digest.lower()
        name = normalize_manifest_path(name, line_number)
        if len(digest) != 64 or any(char not in "0123456789abcdef" for char in digest):
            raise ArtifactVerificationError(f"invalid sha256 digest on manifest line {line_number}")
        if name in {MANIFEST_NAME, SIGNATURE_NAME}:
            raise ArtifactVerificationError(f"manifest must not list control file: {name}")
        entries.append((digest, name))
    if not entries:
        raise ArtifactVerificationError("manifest has no file entries")
    return entries


def verify_hmac(archive: zipfile.ZipFile, manifest_bytes: bytes, hmac_key: str) -> bool:
    if not hmac_key:
        return False
    try:
        signature_payload = json.loads(archive.read(SIGNATURE_NAME).decode("utf-8"))
    except KeyError as exc:
        raise ArtifactVerificationError("missing hmac signature") from exc
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ArtifactVerificationError("invalid hmac signature payload") from exc
    if signature_payload.get("algorithm") != "HMAC-SHA256" or signature_payload.get("signed") != MANIFEST_NAME:
        raise ArtifactVerificationError("invalid hmac signature metadata")
    expected = hmac.new(hmac_key.encode("utf-8"), manifest_bytes, hashlib.sha256).hexdigest()
    actual = str(signature_payload.get("signature") or "")
    if not hmac.compare_digest(actual, expected):
        raise ArtifactVerificationError("hmac mismatch")
    return True


def verify_bundle(bundle_path: str | Path, hmac_key: str = "") -> dict[str, Any]:
    path = Path(bundle_path)
    if not path.is_file():
        raise ArtifactVerificationError(f"bundle not found: {path}")
    with zipfile.ZipFile(path) as archive:
        try:
            manifest_bytes = archive.read(MANIFEST_NAME)
        except KeyError as exc:
            raise ArtifactVerificationError("missing MANIFEST.sha256") from exc
        try:
            manifest_text = manifest_bytes.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ArtifactVerificationError("manifest is not utf-8") from exc
        entries = parse_manifest(manifest_text)
        names = {name.replace("\\", "/") for name in archive.namelist()}
        for expected_digest, name in entries:
            if name not in names:
                raise ArtifactVerificationError(f"manifest entry missing from archive: {name}")
            actual_digest = hashlib.sha256(archive.read(name)).hexdigest()
            if not hmac.compare_digest(actual_digest, expected_digest):
                raise ArtifactVerificationError(f"sha256 mismatch: {name}")
        hmac_verified = verify_hmac(archive, manifest_bytes, hmac_key)
    return {
        "ok": True,
        "bundle": str(path),
        "bundle_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "files_verified": len(entries),
        "hmac_verified": hmac_verified,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Verify a SepsisCare artifact ZIP bundle")
    parser.add_argument("bundle", help="Path to sepsiscare_model_artifacts_latest.zip")
    parser.add_argument("--hmac-key-env", default="", help="Environment variable that contains the HMAC signing key")
    args = parser.parse_args(argv)
    hmac_key = os.getenv(args.hmac_key_env, "") if args.hmac_key_env else ""
    try:
        result = verify_bundle(args.bundle, hmac_key=hmac_key)
    except ArtifactVerificationError as exc:
        print(f"not ok: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
