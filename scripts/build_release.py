#!/usr/bin/env python3
"""Build a deterministic, source-preserving FiveM release archive.

The builder stages a filtered copy, builds the NUI in that copy, writes a
hash manifest, and emits a zip without changing the working tree.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

VERSION_RE = re.compile(r"^v?\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$")
ZIP_EPOCH = (1980, 1, 1, 0, 0, 0)
NORMALIZED_MTIME = 315532800
EXCLUDED_DIRS = {
    ".git",
    ".codebase-memory",
    ".superpowers",
    ".codex",
    ".agents",
    ".github",
    "node_modules",
    "tests",
    "dist",
    "logs",
    "cache",
    "__pycache__",
}
EXCLUDED_FILES = {".env", ".env.local", ".env.production"}


def should_skip(path: Path, root: Path) -> bool:
    rel = path.relative_to(root)
    if any(part in EXCLUDED_DIRS or part.lower() == "dev" for part in rel.parts):
        return True
    return path.name in EXCLUDED_FILES or path.name.startswith(".env.")


def copy_runtime_tree(source: Path, staging: Path) -> None:
    for path in source.rglob("*"):
        if path.is_symlink():
            continue
        if should_skip(path, source):
            continue
        target = staging / path.relative_to(source)
        if path.is_dir():
            target.mkdir(parents=True, exist_ok=True)
        elif path.is_file():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)
            os.utime(target, (NORMALIZED_MTIME, NORMALIZED_MTIME))


def build_nui(staging: Path) -> None:
    web = staging / "web"
    if not (web / "package.json").exists():
        raise RuntimeError("web/package.json is missing")
    npm = "npm.cmd" if os.name == "nt" else "npm"
    subprocess.run([npm, "ci", "--ignore-scripts"], cwd=web, check=True)
    subprocess.run([npm, "run", "build"], cwd=web, check=True)
    shutil.rmtree(web / "node_modules", ignore_errors=True)


def file_manifest(root: Path, version: str) -> dict:
    entries = []
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        entries.append({"path": path.relative_to(root).as_posix(), "sha256": digest, "bytes": path.stat().st_size})
    return {"name": "gnsh-nightshift", "version": version, "files": entries}


def write_manifest(root: Path, version: str) -> None:
    manifest = file_manifest(root, version)
    (root / "RELEASE-MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def resolve_output(source: Path, requested: Path | None) -> Path:
    """Resolve output outside the source tree when no path was supplied."""
    return (requested if requested is not None else source.parent / f"{source.name}-release").resolve()


def archive(root: Path, output: Path, version: str) -> Path:
    output.parent.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)
    archive_path = output / f"gnsh-nightshift-{version}.zip"
    with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as handle:
        for path in sorted(p for p in root.rglob("*") if p.is_file()):
            name = (Path("gnsh-nightshift") / path.relative_to(root)).as_posix()
            entry = zipfile.ZipInfo(name, date_time=ZIP_EPOCH)
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            handle.writestr(entry, path.read_bytes())
    return archive_path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="release version, for example 1.0.0")
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="output directory (defaults to a sibling of the source tree)",
    )
    args = parser.parse_args()
    version = args.version.lstrip("v")
    if not VERSION_RE.fullmatch(version):
        parser.error("--version must be semver-like, e.g. 1.0.0 or 1.0.0-rc.1")
    source = args.source.resolve()
    output = resolve_output(source, args.output)
    if not source.is_dir() or output == source or source in output.parents:
        parser.error("source must be a directory and output must not be the source tree")
    with tempfile.TemporaryDirectory(prefix="gnsh-nightshift-release-") as temp:
        staging = Path(temp) / "gnsh-nightshift"
        staging.mkdir()
        copy_runtime_tree(source, staging)
        build_nui(staging)
        write_manifest(staging, version)
        result = archive(staging, output, version)
    print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
