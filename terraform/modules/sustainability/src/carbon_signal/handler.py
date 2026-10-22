"""Grid carbon-intensity collector (ADR-008).

Every 15 minutes: fetch the ENTSO-E generation mix for each bidding zone, compute
gCO2e/kWh, and publish
  - CloudWatch metric Hestia/Carbon GridIntensity{zone}
  - SSM String /hestia/<env>/carbon/<zone>/current
  - SSM String /hestia/<env>/carbon/<zone>/best_window (lowest-intensity window, next 24 h)

The ENTSO-E token is read at run time from the Secrets Manager secret named by
ENTSOE_TOKEN_SECRET_ARN. It is never logged and never leaves this process except in
the request to the ENTSO-E API.
"""

import json
import logging
import os
import re
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

API_URL = "https://web-api.tp.entsoe.eu/api"

# ENTSO-E EIC codes of the bidding zones Hestia runs in.
ZONES = {
    "DE-LU": "10Y1001A1001A82H",
    "FR": "10YFR-RTE------C",
}

# Life-cycle emission factors in gCO2e/kWh per ENTSO-E production type (psrType).
# Source: IPCC AR5 WG3 (2014), Annex III, Table A.III.2, life-cycle median values.
# Types without an IPCC median carry a Hestia estimate, marked "est."; reports state this.
EMISSION_FACTORS = {
    "B01": 230,  # Biomass (IPCC: biomass dedicated)
    "B02": 820,  # Fossil brown coal / lignite (IPCC: coal)
    "B03": 490,  # Fossil coal-derived gas (IPCC: gas combined cycle)
    "B04": 490,  # Fossil gas (IPCC: gas combined cycle)
    "B05": 820,  # Fossil hard coal (IPCC: coal)
    "B06": 650,  # Fossil oil (est.: between gas and coal)
    "B07": 650,  # Fossil oil shale (est.: as oil)
    "B08": 820,  # Fossil peat (est.: as coal)
    "B09": 38,  # Geothermal (IPCC)
    "B10": 24,  # Hydro pumped storage, generation (est.: as hydropower)
    "B11": 24,  # Hydro run-of-river (IPCC: hydropower)
    "B12": 24,  # Hydro water reservoir (IPCC: hydropower)
    "B13": 24,  # Marine (est.: as hydropower)
    "B14": 12,  # Nuclear (IPCC)
    "B15": 38,  # Other renewable (est.: as geothermal)
    "B16": 48,  # Solar (IPCC: solar PV utility)
    "B17": 230,  # Waste (est.: as biomass)
    "B18": 12,  # Wind offshore (IPCC)
    "B19": 11,  # Wind onshore (IPCC)
    "B20": 700,  # Other (est.: conservative fossil-heavy mix)
}

WIND_SOLAR = ("B16", "B18", "B19")

_RESOLUTION = re.compile(r"^PT(\d+)M$")


def _parse_time(value):
    # ENTSO-E uses e.g. 2026-10-22T10:00Z
    return datetime.strptime(value, "%Y-%m-%dT%H:%MZ").replace(tzinfo=timezone.utc)


def parse_series(xml_text):
    """Parse an ENTSO-E GL_MarketDocument into {timestamp: {psrType: MW}}.

    Only generation series (inBiddingZone) are kept; consumption series such as
    pumped-storage pumping (outBiddingZone) are ignored. Curve type A03 omits points
    whose value repeats, so missing positions carry the previous quantity forward.
    A series without a psrType (total-generation forecasts) is keyed "total".
    """
    root = ET.fromstring(xml_text)
    out = {}
    for ts in root.iterfind(".//{*}TimeSeries"):
        if ts.find("{*}outBiddingZone_Domain.mRID") is not None and ts.find("{*}inBiddingZone_Domain.mRID") is None:
            continue
        psr = ts.findtext("{*}MktPSRType/{*}psrType") or "total"
        for period in ts.iterfind("{*}Period"):
            start = _parse_time(period.findtext("{*}timeInterval/{*}start"))
            end = _parse_time(period.findtext("{*}timeInterval/{*}end"))
            match = _RESOLUTION.match(period.findtext("{*}resolution") or "")
            if not match:
                raise ValueError("unsupported resolution in ENTSO-E series")
            step = timedelta(minutes=int(match.group(1)))
            points = {
                int(p.findtext("{*}position")): float(p.findtext("{*}quantity"))
                for p in period.iterfind("{*}Point")
            }
            last = None
            for i in range(int((end - start) / step)):
                last = points.get(i + 1, last)
                if last is not None:
                    slot = out.setdefault(start + i * step, {})
                    slot[psr] = slot.get(psr, 0.0) + last
    return out


def intensity(mix):
    """Generation-weighted gCO2e/kWh of a {psrType: MW} mix; unknown types count as B20."""
    total = sum(mw for mw in mix.values() if mw > 0)
    if total <= 0:
        raise ValueError("generation mix is empty")
    return sum(mw * EMISSION_FACTORS.get(psr, EMISSION_FACTORS["B20"]) for psr, mw in mix.items() if mw > 0) / total


def latest(series):
    """(timestamp, mix) of the newest slot that has generation."""
    for ts in sorted(series, reverse=True):
        if sum(series[ts].values()) > 0:
            return ts, series[ts]
    raise ValueError("no generation data")


def forecast_intensity(total_fc, wind_solar_fc, current_mix):
    """Estimate gCO2e/kWh for each forecast slot.

    ENTSO-E forecasts only total generation and wind/solar per type. The remainder is
    assumed to keep the intensity of the current non-wind/solar mix.
    """
    rest = {k: v for k, v in current_mix.items() if k not in WIND_SOLAR}
    rest_intensity = intensity(rest) if sum(rest.values()) > 0 else 0.0
    out = {}
    for ts, slot in total_fc.items():
        total = slot.get("total", 0.0)
        if total <= 0:
            continue
        ws = {k: v for k, v in wind_solar_fc.get(ts, {}).items() if k in WIND_SOLAR and v > 0}
        ws_total = min(sum(ws.values()), total)
        scale = ws_total / sum(ws.values()) if ws else 0.0
        grams = sum(v * scale * EMISSION_FACTORS[k] for k, v in ws.items()) + (total - ws_total) * rest_intensity
        out[ts] = grams / total
    return out


def best_window(forecast, hours, now):
    """Lowest-mean contiguous window of `hours` within the next 24 h, or None.

    Returns {"start", "end", "gco2e_per_kwh"} with ISO-8601 UTC times.
    """
    horizon = now + timedelta(hours=24)
    slots = sorted(ts for ts in forecast if now <= ts < horizon)
    if len(slots) < 2:
        return None
    step = min(b - a for a, b in zip(slots, slots[1:]))
    width = int(timedelta(hours=hours) / step)
    best = None
    for i in range(len(slots) - width + 1):
        window = slots[i : i + width]
        if window[-1] - window[0] != step * (width - 1):
            continue  # gap in the forecast
        mean = sum(forecast[t] for t in window) / width
        if best is None or mean < best[1]:
            best = (window[0], mean)
    if best is None:
        return None
    return {
        "start": best[0].isoformat(),
        "end": (best[0] + step * width).isoformat(),
        "gco2e_per_kwh": round(best[1], 1),
    }


def _fetch(token, params):
    query = urllib.parse.urlencode({**params, "securityToken": token})
    with urllib.request.urlopen(f"{API_URL}?{query}", timeout=20) as resp:  # noqa: S310 (fixed https URL)
        return resp.read()


def _fmt(ts):
    return ts.strftime("%Y%m%d%H%M")


def collect(zone, eic, token, now, hours):
    hour = now.replace(minute=0, second=0, microsecond=0)
    actual = parse_series(
        _fetch(token, {"documentType": "A75", "processType": "A16", "in_Domain": eic,
                       "periodStart": _fmt(hour - timedelta(hours=3)), "periodEnd": _fmt(hour + timedelta(hours=1))})
    )
    at, mix = latest(actual)
    window = None
    try:
        span = {"in_Domain": eic, "processType": "A01",
                "periodStart": _fmt(hour), "periodEnd": _fmt(hour + timedelta(hours=25))}
        total_fc = parse_series(_fetch(token, {"documentType": "A71", **span}))
        ws_fc = parse_series(_fetch(token, {"documentType": "A69", **span}))
        window = best_window(forecast_intensity(total_fc, ws_fc, mix), hours, now)
    except Exception:  # forecast is best-effort; consumers fail open on a missing window (ADR-008)
        LOG.warning("zone %s: forecast unavailable", zone)
    return at, intensity(mix), window


def handler(event, context):
    import boto3  # Lambda runtime dependency; keeps the pure functions importable without it

    env = os.environ["ENVIRONMENT"]
    hours = int(os.environ.get("BEST_WINDOW_HOURS", "4"))
    token = boto3.client("secretsmanager").get_secret_value(SecretId=os.environ["ENTSOE_TOKEN_SECRET_ARN"])["SecretString"]
    ssm = boto3.client("ssm")
    cloudwatch = boto3.client("cloudwatch")
    now = datetime.now(timezone.utc)

    failed = []
    for zone, eic in ZONES.items():
        try:
            at, value, window = collect(zone, eic, token, now, hours)
        except Exception as exc:
            LOG.error("zone %s: collection failed: %s", zone, type(exc).__name__)
            failed.append(zone)
            continue

        cloudwatch.put_metric_data(
            Namespace="Hestia/Carbon",
            MetricData=[{"MetricName": "GridIntensity", "Dimensions": [{"Name": "zone", "Value": zone}],
                         "Timestamp": at, "Value": value, "Unit": "None"}],
        )
        prefix = f"/hestia/{env}/carbon/{zone}"
        current = {"gco2e_per_kwh": round(value, 1), "at": at.isoformat(), "source": "ENTSO-E A75", "factors": "IPCC AR5 WG3 Annex III"}
        ssm.put_parameter(Name=f"{prefix}/current", Value=json.dumps(current), Type="String", Overwrite=True)
        if window:
            ssm.put_parameter(Name=f"{prefix}/best_window", Value=json.dumps(window), Type="String", Overwrite=True)
        LOG.info("zone %s: %.1f gCO2e/kWh at %s, window %s", zone, value, at.isoformat(), window)

    if failed:
        raise RuntimeError(f"carbon signal failed for zones: {', '.join(failed)}")
    return {"zones": list(ZONES)}
