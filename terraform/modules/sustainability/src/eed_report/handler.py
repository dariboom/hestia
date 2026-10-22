"""Monthly EED Article 12-aligned sustainability report.

Runs the Athena named queries eed_art12_report and tenant_carbon_monthly for one month, combines
the AWS Customer Carbon Footprint Tool (CCFT) emissions with AWS-published regional PUE/WUE, and
writes reports/eed-art12/<yyyy-mm>.json to the audit bucket (Object Lock keeps it immutable).

Hestia operates no data centre in scope of Article 12, so the report is a voluntary disclosure.
"""

import json
import logging
import os
import re
import time
from datetime import datetime, timezone

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

DISCLOSURE = (
    "Voluntary, Article-12-aligned disclosure. Hestia does not operate a data centre in scope of "
    "Article 12 of Directive (EU) 2023/1791 (Energy Efficiency Directive); it runs on AWS. Emissions "
    "are AWS Customer Carbon Footprint Tool estimates for Hestia's AWS usage. PUE and WUE are the "
    "values AWS publishes per region, not measurements of Hestia's share."
)

MONTH = re.compile(r"^[0-9]{4}-(0[1-9]|1[0-2])$")


def report_month(now, lag_months):
    """The month lag_months before now's month, as yyyy-mm (CCFT data arrives after month end)."""
    index = now.year * 12 + now.month - 1 - lag_months
    return f"{index // 12:04d}-{index % 12 + 1:02d}"


def rows(pages):
    """Athena GetQueryResults pages to a list of dicts; the first row of the first page is the header."""
    header, out = None, []
    for page in pages:
        for row in page["ResultSet"]["Rows"]:
            values = [d.get("VarCharValue") for d in row["Data"]]
            if header is None:
                header = values
            else:
                out.append(dict(zip(header, values)))
    return out


def _num(value):
    return None if value in (None, "") else float(value)


def build_report(month, environment, region_rows, tenant_rows, factors, generated_at):
    regions = []
    for r in sorted(region_rows, key=lambda r: r["region_code"]):
        f = factors.get(r["region_code"], {})
        regions.append(
            {
                "region_code": r["region_code"],
                "lbm_mtco2e": _num(r["lbm_mtco2e"]),
                "mbm_mtco2e": _num(r["mbm_mtco2e"]),
                "pue": f.get("pue"),
                "wue_l_per_kwh": f.get("wue"),
                "pue_wue_source": f.get("source_url"),
            }
        )
    tenants = [
        {"tenant": t["tenant"], "lbm_mtco2e": _num(t["lbm_mtco2e"]), "mbm_mtco2e": _num(t["mbm_mtco2e"])}
        for t in sorted(tenant_rows, key=lambda t: t["tenant"])
    ]
    return {
        "report": "EED Article 12-aligned sustainability disclosure",
        "disclosure": DISCLOSURE,
        "period": month,
        "environment": environment,
        "generated_at": generated_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "unit": "MTCO2e",
        "totals": {
            "lbm_mtco2e": sum(r["lbm_mtco2e"] or 0 for r in regions),
            "mbm_mtco2e": sum(r["mbm_mtco2e"] or 0 for r in regions),
        },
        "regions": regions,
        "tenants": tenants,
        "methodology": {
            "emissions": "AWS Customer Carbon Footprint Tool via BCM Data Exports (CARBON_EMISSIONS), location- and market-based.",
            "tenant_allocation": "Each region and service's emissions are split by the tenant's share of its cost (CUR 2.0 with split cost allocation data for EKS); untagged cost is reported as tenant 'shared'.",
            "pue_wue": "AWS-published regional values; null where AWS publishes none (e.g. global services).",
            "not_reported": "Energy consumption in kWh, renewable energy share and waste-heat reuse: AWS does not publish them per customer.",
        },
    }


def _run(athena, workgroup, query_id, month, timeout_s=300):
    sql = athena.get_named_query(NamedQueryId=query_id)["NamedQuery"]["QueryString"]
    qid = athena.start_query_execution(
        QueryString=sql, WorkGroup=workgroup, ExecutionParameters=[f"'{month}'"]
    )["QueryExecutionId"]
    deadline = time.monotonic() + timeout_s
    while True:
        status = athena.get_query_execution(QueryExecutionId=qid)["QueryExecution"]["Status"]
        if status["State"] == "SUCCEEDED":
            break
        if status["State"] in ("FAILED", "CANCELLED") or time.monotonic() > deadline:
            raise RuntimeError(f"query {query_id} {status['State']}: {status.get('StateChangeReason', 'timeout')}")
        time.sleep(2)
    return rows(athena.get_paginator("get_query_results").paginate(QueryExecutionId=qid))


def handler(event, context):
    now = datetime.now(timezone.utc)
    month = (event or {}).get("month") or report_month(now, int(os.environ.get("REPORT_LAG_MONTHS", "1")))
    if not MONTH.match(month):  # the month is inlined as a SQL literal
        raise ValueError("month must be yyyy-mm")

    import boto3  # Lambda runtime dependency; keeps the pure functions importable without it

    athena = boto3.client("athena")
    workgroup = os.environ["WORKGROUP"]
    report = build_report(
        month,
        os.environ["ENVIRONMENT"],
        _run(athena, workgroup, os.environ["EED_QUERY_ID"], month),
        _run(athena, workgroup, os.environ["TENANT_QUERY_ID"], month),
        json.loads(os.environ["DATACENTRE_FACTORS"]),
        now,
    )
    key = f"reports/eed-art12/{month}.json"
    boto3.client("s3").put_object(
        Bucket=os.environ["AUDIT_BUCKET"],
        Key=key,
        Body=json.dumps(report, indent=2).encode(),
        ContentType="application/json",
    )
    LOG.info("wrote %s (%d regions, %d tenants)", key, len(report["regions"]), len(report["tenants"]))
    return {"key": key}
