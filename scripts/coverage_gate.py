#!/usr/bin/env python3
"""Enforce a measured LuaCov line-coverage threshold.

LuaCov has emitted a few compatible report layouts over time.  This parser
accepts both the table-style per-file rows and the summary rows while refusing
to pass an empty or unrecognised report.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import PurePath


PERCENT = re.compile(r"(?P<pct>\d+(?:\.\d+)?)\s*%")
COUNTS = re.compile(r"(?:\(|\s)(?P<hit>\d+)\s*/\s*(?P<total>\d+)(?:\)|\s)")
# LuaCov has emitted both pipe-delimited rows and whitespace-column rows.  The
# path must be extracted independently of the hit/missed columns so the gate
# cannot silently fall back to a summary when a valid per-file report is used.
PRODUCTION = re.compile(
    r"(?P<path>(?:[A-Za-z]:)?(?:[^|\s]*[\\/])?"
    r"(?:client|server|shared|config)[\\/][^|\s]*?\.lua)",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class Row:
    path: str
    percent: float
    hit: int | None = None
    total: int | None = None


def _normalise(path: str) -> str:
    return path.strip().strip("|:").replace("\\", "/")


def parse_report(text: str) -> tuple[list[Row], Row | None]:
    rows: list[Row] = []
    summary: Row | None = None
    for raw_line in text.splitlines():
        line = raw_line.strip()
        percent_match = PERCENT.search(line)
        if not percent_match:
            continue
        percent = float(percent_match.group("pct"))
        counts_match = COUNTS.search(line)
        hit = int(counts_match.group("hit")) if counts_match else None
        total = int(counts_match.group("total")) if counts_match else None
        path_match = PRODUCTION.search(line)
        path = _normalise(path_match.group("path")) if path_match else ""
        if path_match and PRODUCTION.search(path):
            rows.append(Row(path, percent, hit, total))
        elif re.search(r"\b(?:total|summary|overall)\b", line, re.IGNORECASE):
            summary = Row("<summary>", percent, hit, total)
    return rows, summary


def _matches_scope(path: str, scopes: list[str]) -> bool:
    if not scopes:
        return True
    normalized = path.replace("\\", "/")
    return any(normalized.endswith(scope.replace("\\", "/")) for scope in scopes)


def enforce(report: str, minimum: float = 80.0, scopes: list[str] | None = None) -> tuple[float, int]:
    rows, summary = parse_report(report)
    selected = [row for row in rows if _matches_scope(row.path, scopes or [])]
    if scopes and not selected:
        raise ValueError("coverage report contains no rows for the requested production scope")
    if not selected and summary is None:
        raise ValueError("coverage report is empty or has an unrecognised format")
    failing = [row for row in selected if row.percent < minimum]
    if failing:
        details = ", ".join(f"{row.path}={row.percent:.1f}%" for row in failing[:8])
        raise ValueError(f"coverage below {minimum:.1f}%: {details}")
    if selected:
        counted = [row for row in selected if row.hit is not None and row.total]
        if counted:
            hit = sum(row.hit or 0 for row in counted)
            total = sum(row.total or 0 for row in counted)
            measured = (hit / total * 100.0) if total else 0.0
        else:
            measured = sum(row.percent for row in selected) / len(selected)
        if measured < minimum:
            raise ValueError(f"weighted coverage below {minimum:.1f}%: {measured:.1f}%")
        return measured, len(selected)
    measured = summary.percent
    if measured < minimum:
        raise ValueError(f"summary coverage below {minimum:.1f}%: {measured:.1f}%")
    return measured, 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", help="LuaCov report output")
    parser.add_argument("--minimum", type=float, default=80.0)
    parser.add_argument("--scope", action="append", default=[], help="production file suffix to enforce")
    args = parser.parse_args(argv)
    try:
        report = PurePath(args.report)
        # PurePath is only used for a platform-neutral display; open through
        # the regular path API so Windows and POSIX runners behave identically.
        from pathlib import Path

        measured, rows = enforce(Path(report).read_text(encoding="utf-8"), args.minimum, args.scope)
    except (OSError, ValueError) as exc:
        print(f"coverage gate failed: {exc}", file=sys.stderr)
        return 1
    print(f"coverage gate passed: {measured:.1f}% across {rows} production file(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
