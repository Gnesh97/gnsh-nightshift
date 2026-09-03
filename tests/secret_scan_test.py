import tempfile
import unittest
from pathlib import Path

from scripts.secret_scan import scan


class SecretScanTests(unittest.TestCase):
    def test_source_fixture_is_clean(self) -> None:
        root = Path(__file__).resolve().parents[1]
        self.assertEqual(scan(root), [])

    def test_high_signal_credentials_fail(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.txt"
            openai_prefix = "sk-"
            openai_value = openai_prefix + ("a" * 24)
            path.write_text(f"value={openai_value}\n", encoding="utf-8")
            findings = scan(path)
            self.assertEqual(len(findings), 1)
            self.assertEqual(findings[0].kind, "OpenAI key")

    def test_generic_fixture_token_is_not_a_secret(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.lua"
            path.write_text('local sampleValue = "fixture-token"\n', encoding="utf-8")
            self.assertEqual(scan(path), [])


if __name__ == "__main__":
    unittest.main()
