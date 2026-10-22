"""Stdlib tests for the pure functions: python3 -m unittest (no boto3, no network)."""

import unittest
from datetime import datetime, timezone

import handler


def page(*rows):
    return {"ResultSet": {"Rows": [{"Data": [{"VarCharValue": v} if v is not None else {} for v in r]} for r in rows]}}


class ReportMonth(unittest.TestCase):
    def test_previous_month(self):
        self.assertEqual(handler.report_month(datetime(2026, 10, 25, tzinfo=timezone.utc), 1), "2026-09")

    def test_crosses_year(self):
        self.assertEqual(handler.report_month(datetime(2026, 1, 25, tzinfo=timezone.utc), 1), "2025-12")
        self.assertEqual(handler.report_month(datetime(2026, 2, 1, tzinfo=timezone.utc), 3), "2025-11")


class Rows(unittest.TestCase):
    def test_header_only_on_first_page(self):
        pages = [page(["tenant", "mbm_mtco2e"], ["a", "1.5"]), page(["b", None])]
        self.assertEqual(handler.rows(pages), [{"tenant": "a", "mbm_mtco2e": "1.5"}, {"tenant": "b", "mbm_mtco2e": None}])


class BuildReport(unittest.TestCase):
    def setUp(self):
        self.report = handler.build_report(
            "2026-09",
            "prod",
            [
                {"region_code": "eu-west-3", "lbm_mtco2e": "0.25", "mbm_mtco2e": "0.0"},
                {"region_code": "eu-central-1", "lbm_mtco2e": "1.0", "mbm_mtco2e": "0.5"},
                {"region_code": "us-east-1", "lbm_mtco2e": "0.01", "mbm_mtco2e": None},
            ],
            [{"tenant": "t2", "lbm_mtco2e": "0.5", "mbm_mtco2e": "0.25"}, {"tenant": "shared", "lbm_mtco2e": "0.75", "mbm_mtco2e": "0.25"}],
            {"eu-central-1": {"pue": 1.15, "wue": 0.2, "source_url": "https://example.org/aws-pue"}},
            datetime(2026, 10, 25, 6, 0, tzinfo=timezone.utc),
        )

    def test_states_voluntary_article_12_aligned(self):
        self.assertIn("Voluntary, Article-12-aligned", self.report["disclosure"])

    def test_totals_skip_missing_values(self):
        self.assertAlmostEqual(self.report["totals"]["lbm_mtco2e"], 1.26)
        self.assertAlmostEqual(self.report["totals"]["mbm_mtco2e"], 0.5)

    def test_factors_joined_by_region_and_null_when_unpublished(self):
        regions = {r["region_code"]: r for r in self.report["regions"]}
        self.assertEqual(list(regions), ["eu-central-1", "eu-west-3", "us-east-1"])
        self.assertEqual(regions["eu-central-1"]["pue"], 1.15)
        self.assertEqual(regions["eu-central-1"]["pue_wue_source"], "https://example.org/aws-pue")
        self.assertIsNone(regions["eu-west-3"]["pue"])

    def test_tenants_sorted(self):
        self.assertEqual([t["tenant"] for t in self.report["tenants"]], ["shared", "t2"])
        self.assertEqual(self.report["generated_at"], "2026-10-25T06:00:00Z")


class Handler(unittest.TestCase):
    def test_rejects_month_that_is_not_yyyy_mm(self):
        with self.assertRaises(ValueError):
            handler.handler({"month": "2026-09' OR 1=1 --"}, None)


if __name__ == "__main__":
    unittest.main()
