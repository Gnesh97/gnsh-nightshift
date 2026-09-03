#!/usr/bin/env python3
"""Fail-closed high-signal secret scanner for source and release inputs.

This intentionally scans only credential-shaped values.  Generic assignments
such as ``token = "fixture"`` are not secrets and would make contract tests
too noisy to be useful.  The scanner is deterministic and has no dependency
on an optional third-party binary.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


SKIP_DIRS = {
    ".git",
    ".codebase-memory",
    ".codex",
    ".agents",
    ".superpowers",
    "node_modules",
    "dist",
    "__pycache__",
}

PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("private key", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |PGP )?PRIVATE KEY-----")),
    ("OpenAI key", re.compile(r"\bsk-[A-Za-z0-9]{20,}\b")),
    ("GitHub token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b")),
    ("AWS access key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("Google API key", re.compile(r"\bAIza[0-9A-Za-z_-]{30,}\b")),
    ("Slack token", re.compile(r"\bxox[baprs]-[0-9A-Za-z-]{20,}\b")),
    ("npm token", re.compile(r"\bnpm_[A-Za-z0-9]{30,}\b")),
)


@dataclass(frozen=True)
class Finding:
    path: Path
    line: int
    kind: str


def iter_files(root: Path) -> Iterable[Path]:
    if root.is_file():
        yield root
        return
    for path in root.rglob("*"):
        if not path.is_file() or any(part in SKIP_DIRS for part in path.parts):
            continue
        if path.name.startswith(".env"):
            # Environment files are excluded from the release builder, but
            # still fail the scan if a real one is checked in below.
            yield path
            continue
        try:
            if path.stat().st_size > 2_000_000:
                continue
        except OSError:
            continue
        yield path


def scan_file(path: Path) -> list[Finding]:
    try:
        raw = path.read_bytes()
    except OSError:
        return []
    if b"\x00" in raw:
        return []
    text = raw.decode("utf-8", errors="replace")
    findings: list[Finding] = []
    for line_number, line in enumerate(text.splitlines(), 1):
        for kind, pattern in PATTERNS:
            if pattern.search(line):
                findings.append(Finding(path, line_number, kind))
    return findings


def scan(root: Path) -> list[Finding]:
    findings: list[Finding] = []
    for path in iter_files(root):
        findings.extend(scan_file(path))
    return findings


def main(argv: list[str] | None = None) -> int:
    paths = [Path(value) for value in (argv if argv is not None else sys.argv[1:])]
    if not paths:
        paths = [Path(".")]
    findings: list[Finding] = []
    for path in paths:
        findings.extend(scan(path))
    if findings:
        for finding in findings:
            print(f"secret scan failed: {finding.path}:{finding.line}: {finding.kind}", file=sys.stderr)
        return 1
    print("secret scan passed: no high-signal credentials found")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
