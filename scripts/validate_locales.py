#!/usr/bin/env python3
"""Validate that shipped locale bundles are valid and key-identical."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


def _flatten(value: Any, prefix: str = "") -> dict[str, Any]:
    if not isinstance(value, dict):
        return {prefix: value}
    flattened: dict[str, Any] = {}
    for key, child in value.items():
        path = f"{prefix}.{key}" if prefix else str(key)
        flattened.update(_flatten(child, path))
    return flattened


def load_locale(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"invalid locale {path}: {exc}") from exc
    if not isinstance(value, dict) or not value:
        raise ValueError(f"locale must be a non-empty object: {path}")
    flattened = _flatten(value)
    empty = [key for key, item in flattened.items() if not isinstance(item, str) or not item.strip()]
    if empty:
        raise ValueError(f"locale has empty/non-string values in {path}: {', '.join(sorted(empty))}")
    return flattened


def validate(directory: Path) -> tuple[int, int]:
    english_path = directory / "en.json"
    turkish_path = directory / "tr.json"
    english = load_locale(english_path)
    turkish = load_locale(turkish_path)
    english_keys, turkish_keys = set(english), set(turkish)
    missing = sorted(english_keys - turkish_keys)
    extra = sorted(turkish_keys - english_keys)
    if missing or extra:
        details = []
        if missing:
            details.append(f"missing in tr.json: {', '.join(missing)}")
        if extra:
            details.append(f"extra in tr.json: {', '.join(extra)}")
        raise ValueError("locale key parity failed; " + "; ".join(details))
    return len(english_keys), len(turkish_keys)


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    directory = Path(args[0]) if args else Path("locales")
    try:
        en_count, tr_count = validate(directory)
    except ValueError as exc:
        print(f"locale validation failed: {exc}", file=sys.stderr)
        return 1
    print(f"locale parity ok: en={en_count} tr={tr_count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
