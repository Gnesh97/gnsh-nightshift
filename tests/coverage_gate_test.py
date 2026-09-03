import unittest

from scripts.coverage_gate import enforce, parse_report


class CoverageGateTests(unittest.TestCase):
    def test_parses_luacov_style_rows_and_summary(self) -> None:
        report = """
        server/services/example.lua | 90.0% (9/10)
        client/npc/example.lua | 80.0% (8/10)
        Total | 85.0% (17/20)
        """
        rows, summary = parse_report(report)
        self.assertEqual(len(rows), 2)
        self.assertEqual(summary.percent, 85.0)
        measured, count = enforce(report)
        self.assertEqual(count, 2)
        self.assertAlmostEqual(measured, 85.0)

    def test_scope_and_threshold_are_fail_closed(self) -> None:
        report = "server/a.lua | 79.9% (799/1000)"
        with self.assertRaisesRegex(ValueError, "below"):
            enforce(report, scopes=["server/a.lua"])
        with self.assertRaisesRegex(ValueError, "no rows"):
            enforce(report, scopes=["client/a.lua"])

    def test_parses_whitespace_column_rows(self) -> None:
        report = """
        server/services/example.lua        9       1       90.0%
        client/npc/example.lua             8       2       80.0%
        """
        rows, summary = parse_report(report)
        self.assertIsNone(summary)
        self.assertEqual([row.path for row in rows], [
            "server/services/example.lua",
            "client/npc/example.lua",
        ])
        measured, count = enforce(report)
        self.assertEqual(count, 2)
        self.assertAlmostEqual(measured, 85.0)


if __name__ == "__main__":
    unittest.main()
