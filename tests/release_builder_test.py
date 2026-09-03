import importlib.util
import json
import os
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("build_release", ROOT / "scripts" / "build_release.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MODULE)


class ReleaseBuilderTests(unittest.TestCase):
    def test_filters_non_runtime_content(self):
        with tempfile.TemporaryDirectory() as temp:
            source, staging = Path(temp) / "source", Path(temp) / "stage"
            (source / "server" / "dev").mkdir(parents=True)
            (source / "tests").mkdir()
            (source / "config").mkdir()
            (source / ".github" / "workflows").mkdir(parents=True)
            (source / ".codex").mkdir()
            (source / ".agents").mkdir()
            (source / "server" / "main.lua").write_text("ok")
            (source / "server" / "dev" / "smoke.lua").write_text("skip")
            (source / "tests" / "test.lua").write_text("skip")
            (source / ".github" / "workflows" / "ci.yml").write_text("skip")
            (source / ".codex" / "config.toml").write_text("skip")
            (source / ".agents" / "notes.md").write_text("skip")
            (source / "config" / "config.lua").write_text("ok")
            (source / ".env.local").write_text("secret")
            try:
                os.symlink(source / "server" / "main.lua", source / "linked-secret.lua")
            except (OSError, NotImplementedError):
                pass
            staging.mkdir()
            MODULE.copy_runtime_tree(source, staging)
            self.assertTrue((staging / "server/main.lua").exists())
            self.assertTrue((staging / "config/config.lua").exists())
            self.assertFalse((staging / "server/dev/smoke.lua").exists())
            self.assertFalse((staging / "tests/test.lua").exists())
            self.assertFalse((staging / ".github/workflows/ci.yml").exists())
            self.assertFalse((staging / ".codex/config.toml").exists())
            self.assertFalse((staging / ".agents/notes.md").exists())
            self.assertFalse((staging / ".env.local").exists())
            self.assertFalse((staging / "linked-secret.lua").exists())

    def test_default_output_is_a_source_sibling(self):
        source = Path("C:/tmp/gnsh-nightshift").resolve()
        self.assertEqual(
            MODULE.resolve_output(source, None),
            source.parent / "gnsh-nightshift-release",
        )

    def test_manifest_and_archive_are_hashed_and_scoped(self):
        with tempfile.TemporaryDirectory() as temp:
            root, output = Path(temp) / "root", Path(temp) / "out"
            root.mkdir(); (root / "fxmanifest.lua").write_text("manifest")
            MODULE.write_manifest(root, "1.2.3")
            manifest = json.loads((root / "RELEASE-MANIFEST.json").read_text())
            self.assertEqual(manifest["version"], "1.2.3")
            self.assertTrue(any(item["path"] == "fxmanifest.lua" for item in manifest["files"]))
            result = MODULE.archive(root, output, "1.2.3")
            with zipfile.ZipFile(result) as archive:
                names = archive.namelist()
                payload = {name: archive.read(name) for name in names}
            self.assertIn("gnsh-nightshift/fxmanifest.lua", names)
            self.assertNotIn("tests/test.lua", names)
            hashes = {item["path"]: item["sha256"] for item in manifest["files"]}
            for name, content in payload.items():
                relative = name.removeprefix("gnsh-nightshift/")
                if relative == "RELEASE-MANIFEST.json":
                    continue
                self.assertEqual(hashes[relative], __import__("hashlib").sha256(content).hexdigest())

    def test_archives_are_byte_for_byte_deterministic(self):
        with tempfile.TemporaryDirectory() as temp:
            root, output = Path(temp) / "root", Path(temp) / "out"
            root.mkdir(); (root / "file.txt").write_text("stable")
            first = MODULE.archive(root, output, "1.2.3")
            first_bytes = first.read_bytes()
            second = MODULE.archive(root, output, "1.2.3")
            self.assertEqual(first_bytes, second.read_bytes())


if __name__ == "__main__":
    unittest.main()
