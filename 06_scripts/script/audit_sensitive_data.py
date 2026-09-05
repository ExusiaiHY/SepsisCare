#!/usr/bin/env python3
"""Audit release files for committed secrets and PHI-like sensitive text."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path
from typing import Iterable


EXCLUDED_DIRS = {
    ".build",
    ".git",
    ".runtime",
    ".sepsiscare-runtime",
    ".venv",
    "__pycache__",
    "artifacts",
    "DerivedData",
    "dist",
    "docs",
    "models",
    "node_modules",
    "reports",
    "venv",
    "xcuserdata",
}
EXCLUDED_SUFFIXES = {
    ".DS_Store",
    ".icns",
    ".ico",
    ".jar",
    ".lock",
    ".log",
    ".npy",
    ".pkl",
    ".png",
    ".pt",
    ".pyc",
    ".xcuserstate",
    ".zip",
}
TEXT_SUFFIXES = {
    ".bat",
    ".cfg",
    ".conf",
    ".css",
    ".env",
    ".html",
    ".ini",
    ".js",
    ".json",
    ".md",
    ".plist",
    ".ps1",
    ".py",
    ".sh",
    ".swift",
    ".toml",
    ".txt",
    ".yaml",
    ".yml",
}
PHI_SUFFIXES = {".cfg", ".conf", ".csv", ".env", ".ini", ".json", ".toml", ".txt", ".yaml", ".yml"}
SECRET_PATTERNS = (
    re.compile(r"\bsk-(?:live|proj|test)?-?[A-Za-z0-9_-]{24,}\b"),
    re.compile(r"\b(?:DEEPSEEK|OPENAI|ANTHROPIC|SEPSISCARE|API)[A-Z0-9_]*(?:KEY|TOKEN|SECRET)[ \t]*[:=][ \t]*[\"']?([A-Za-z0-9][A-Za-z0-9._~+/=-]{23,})", re.IGNORECASE),
    re.compile(r"\bAuthorization[ \t]*:[ \t]*Bearer[ \t]+([A-Za-z0-9][A-Za-z0-9._~+/=-]{23,})", re.IGNORECASE),
)
PHI_PATTERNS = (
    re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.IGNORECASE),
    re.compile(r"\b(?:MRN|HADM|SUBJECT|SSN|ID)\s*[:：#-]?\s*[A-Za-z0-9_-]{3,}\b", re.IGNORECASE),
    re.compile(r"\b\d{3}-\d{2}-\d{4}\b"),
    re.compile(r"\b(?:DOB|birth|birthday)\s*[:：#-]?\s*\d{4}[-/]\d{1,2}[-/]\d{1,2}\b", re.IGNORECASE),
    re.compile(r"(?<!\d)(?:\+?1[-.\s]?)?(?:\(?\d{3}\)?[-.\s]?)\d{3}[-.\s]?\d{4}(?!\d)"),
)
PLACEHOLDER_WORDS = {
    "bearer",
    "change-me",
    "changeme",
    "example",
    "placeholder",
    "secure-token",
    "service-token",
    "test",
    "token",
    "your-token",
}


def short_hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:12]


def should_skip_path(path: Path, root: Path) -> bool:
    try:
        relative = path.relative_to(root)
    except ValueError:
        relative = path
    parts = set(relative.parts)
    name = path.name
    if parts & EXCLUDED_DIRS:
        return True
    if name.startswith("test_") or name.endswith("_test.py") or name.endswith("Tests.swift"):
        return True
    if name in {"LICENSE.txt", "package-lock.json", "MANIFEST.sha256"}:
        return True
    if name.endswith(".min.js") or name.endswith(".min.css"):
        return True
    return any(name.endswith(suffix) for suffix in EXCLUDED_SUFFIXES)


def is_text_candidate(path: Path) -> bool:
    if path.suffix in TEXT_SUFFIXES:
        return True
    return path.name.startswith(".env")


def is_phi_candidate(path: Path) -> bool:
    return path.suffix in PHI_SUFFIXES or path.name.startswith(".env")


def iter_candidate_files(root: Path) -> Iterable[Path]:
    for dirpath, dirnames, filenames in os.walk(root):
        current = Path(dirpath)
        dirnames[:] = [name for name in dirnames if name not in EXCLUDED_DIRS]
        for filename in filenames:
            path = current / filename
            if should_skip_path(path, root) or not is_text_candidate(path):
                continue
            yield path


def read_text(path: Path) -> str | None:
    try:
        raw = path.read_bytes()
    except OSError:
        return None
    if b"\0" in raw:
        return None
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return None


def matched_value(match: re.Match[str]) -> str:
    if match.groups():
        for group in match.groups():
            if group:
                return group
    return match.group(0)


def looks_like_placeholder(value: str) -> bool:
    lowered = value.lower()
    return any(word in lowered for word in PLACEHOLDER_WORDS)


def line_number_for(text: str, index: int) -> int:
    return text.count("\n", 0, index) + 1


def add_finding(
    findings: list[dict[str, object]],
    category: str,
    path: Path,
    root: Path,
    reported_root: Path,
    line: int,
    value: str,
) -> None:
    relative_file = str(path.relative_to(root))
    evidence_hash = short_hash(value)
    if any(
        finding.get("category") == category
        and finding.get("file") == relative_file
        and finding.get("line") == line
        and finding.get("evidence_hash") == evidence_hash
        for finding in findings
    ):
        return
    findings.append(
        {
            "category": category,
            "root": str(reported_root),
            "file": relative_file,
            "line": line,
            "evidence_hash": evidence_hash,
        }
    )


def audit_file(path: Path, root: Path, reported_root: Path, findings: list[dict[str, object]]) -> None:
    text = read_text(path)
    if text is None:
        return
    for pattern in SECRET_PATTERNS:
        for match in pattern.finditer(text):
            value = matched_value(match)
            if looks_like_placeholder(value):
                continue
            add_finding(findings, "hardcoded_secret", path, root, reported_root, line_number_for(text, match.start()), value)
    if not is_phi_candidate(path):
        return
    for pattern in PHI_PATTERNS:
        for match in pattern.finditer(text):
            add_finding(findings, "sensitive_text", path, root, reported_root, line_number_for(text, match.start()), match.group(0))


def normalize_roots(root_dirs: str | Path | Iterable[str | Path]) -> list[Path]:
    if isinstance(root_dirs, (str, Path)):
        return [Path(root_dirs).resolve()]
    return [Path(root).resolve() for root in root_dirs]


def audit_sensitive_data(root_dirs: str | Path | Iterable[str | Path]) -> dict[str, object]:
    roots = normalize_roots(root_dirs)
    findings: list[dict[str, object]] = []
    for root in roots:
        if not root.exists():
            findings.append({"category": "read_error", "root": str(root), "file": str(root), "line": 0, "evidence_hash": ""})
        elif root.is_file():
            audit_file(root, root.parent, root, findings)
        else:
            for path in iter_candidate_files(root):
                audit_file(path, root, root, findings)
    return {
        "ok": not findings,
        "root": str(roots[0]) if roots else "",
        "roots": [str(root) for root in roots],
        "summary": {"findings": len(findings)},
        "findings": findings,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Audit release files for committed secrets and PHI-like text")
    parser.add_argument("root_dirs", nargs="*", default=["02_model_deploy_package"])
    args = parser.parse_args(argv)
    report = audit_sensitive_data(args.root_dirs)
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if report.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
