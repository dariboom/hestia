"""Stdlib tests for the pure functions: python3 -m unittest (no boto3, no network)."""

import unittest
from datetime import datetime, timedelta, timezone

import handler

NS = "urn:iec62325.351:tc57wg16:451-6:generationloaddocument:3:0"


def series(psr, start, end, resolution, points, domain="inBiddingZone_Domain.mRID"):
    psr_xml = f"<MktPSRType><psrType>{psr}</psrType></MktPSRType>" if psr else ""
    pts = "".join(f"<Point><position>{p}</position><quantity>{q}</quantity></Point>" for p, q in points)
    return (
        f"<TimeSeries><{domain}>10YFR-RTE------C</{domain}>{psr_xml}"
        f"<Period><timeInterval><start>{start}</start><end>{end}</end></timeInterval>"
        f"<resolution>{resolution}</resolution>{pts}</Period></TimeSeries>"
    )


def doc(*ts):
    return f'<GL_MarketDocument xmlns="{NS}">{"".join(ts)}</GL_MarketDocument>'


T0 = datetime(2026, 10, 22, 10, 0, tzinfo=timezone.utc)


class ParseSeries(unittest.TestCase):
    def test_mix_gap_fill_and_consumption_skipped(self):
        xml = doc(
            series("B14", "2026-10-22T10:00Z", "2026-10-22T11:00Z", "PT15M", [(1, 100), (3, 50)]),
            series("B19", "2026-10-22T10:00Z", "2026-10-22T11:00Z", "PT30M", [(1, 20), (2, 40)]),
            series("B10", "2026-10-22T10:00Z", "2026-10-22T11:00Z", "PT60M", [(1, 999)], "outBiddingZone_Domain.mRID"),
        )
        out = handler.parse_series(xml)
        self.assertEqual(out[T0], {"B14": 100.0, "B19": 20.0})
        self.assertEqual(out[T0 + timedelta(minutes=15)]["B14"], 100.0)  # A03 gap carried forward
        self.assertEqual(out[T0 + timedelta(minutes=30)], {"B14": 50.0, "B19": 40.0})
        self.assertNotIn("B10", out[T0])

    def test_total_forecast_has_no_psr(self):
        out = handler.parse_series(doc(series(None, "2026-10-22T10:00Z", "2026-10-22T11:00Z", "PT60M", [(1, 500)])))
        self.assertEqual(out, {T0: {"total": 500.0}})

    def test_unknown_resolution_rejected(self):
        with self.assertRaises(ValueError):
            handler.parse_series(doc(series("B14", "2026-10-22T10:00Z", "2026-10-23T10:00Z", "P1D", [(1, 1)])))


class Intensity(unittest.TestCase):
    def test_weighted_mean(self):
        self.assertAlmostEqual(handler.intensity({"B14": 50, "B05": 50}), (12 + 820) / 2)

    def test_unknown_type_counts_as_other(self):
        self.assertEqual(handler.intensity({"B99": 10}), handler.EMISSION_FACTORS["B20"])

    def test_empty_mix_rejected(self):
        with self.assertRaises(ValueError):
            handler.intensity({"B14": 0})

    def test_latest_skips_empty_slots(self):
        s = {T0: {"B14": 10.0}, T0 + timedelta(hours=1): {"B14": 0.0}}
        self.assertEqual(handler.latest(s), (T0, {"B14": 10.0}))


class Forecast(unittest.TestCase):
    def test_residual_keeps_current_non_wind_solar_intensity(self):
        current = {"B04": 100.0, "B19": 900.0}  # rest = pure gas, 490
        total = {T0: {"total": 1000.0}}
        ws = {T0: {"B19": 500.0}}
        self.assertAlmostEqual(handler.forecast_intensity(total, ws, current)[T0], (500 * 11 + 500 * 490) / 1000)

    def test_wind_solar_capped_at_total(self):
        out = handler.forecast_intensity({T0: {"total": 100.0}}, {T0: {"B19": 300.0}}, {"B04": 1.0})
        self.assertAlmostEqual(out[T0], 11)

    def test_best_window(self):
        fc = {T0 + timedelta(hours=h): v for h, v in enumerate([300, 200, 100, 100, 400, 500])}
        w = handler.best_window(fc, 2, T0)
        self.assertEqual(w["start"], (T0 + timedelta(hours=2)).isoformat())
        self.assertEqual(w["end"], (T0 + timedelta(hours=4)).isoformat())
        self.assertEqual(w["gco2e_per_kwh"], 100.0)

    def test_best_window_skips_gaps_and_past(self):
        fc = {T0 - timedelta(hours=1): 1, T0: 300, T0 + timedelta(hours=1): 300, T0 + timedelta(hours=3): 10, T0 + timedelta(hours=4): 10}
        w = handler.best_window(fc, 2, T0)
        self.assertEqual(w["start"], (T0 + timedelta(hours=3)).isoformat())

    def test_best_window_none_when_too_short(self):
        self.assertIsNone(handler.best_window({T0: 1, T0 + timedelta(hours=1): 1}, 4, T0))


if __name__ == "__main__":
    unittest.main()
