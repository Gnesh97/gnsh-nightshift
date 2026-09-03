import json
import tempfile
import unittest
from pathlib import Path

from scripts.validate_locales import validate


class LocaleValidationTests(unittest.TestCase):
    def test_shipped_locales_have_identical_keys(self) -> None:
        root = Path(__file__).resolve().parents[1]
        english, turkish = validate(root / "locales")
        self.assertEqual(english, turkish)
        self.assertGreater(english, 0)

    def test_key_drift_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "en.json").write_text(json.dumps({"a": "A"}), encoding="utf-8")
            (path / "tr.json").write_text(json.dumps({"b": "B"}), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "parity"):
                validate(path)


if __name__ == "__main__":
    unittest.main()
