"""
Generate the monthly QE volume / baseline report for the PDR funding agreement.

WHAT IT PRODUCES
----------------
A CSV report satisfying the requirement described in the SQL of record:
  - Monthly document count by QE and data type (CCD, TRN, ORU).
  - Rolling 2-month average baseline.
  - pct_of_baseline and a below_10pct_flag ('YES' when a QE's monthly volume is
    more than 10% below its rolling baseline -> considered a PDR outage).

HOW IT WORKS
------------
- The QUERY OF RECORD is the committed SQL file (do NOT edit it):
      QE Funding Agreement Queries/CountByMonthForPayment/Monthly-VolumneByQEByDataType.sql
- This script READS that .sql file and changes ONLY the dates (start_month /
  end_month) for the month you want to assess. To compute the rolling 2-month
  baseline, it automatically includes the 2 calendar months BEFORE your target
  month (per the SQL's own "how to use" note).

USAGE
-----
  python generate_monthly_volume_report.py --month 2026-10
  python generate_monthly_volume_report.py --month 2026-10 --lead-months 2

Requires valid AWS credentials (see ../../athena_hello_world.py --check).
"""

import argparse
import calendar
import csv as csvmod
import os
import re
import sys
from datetime import date

HERE = os.path.dirname(os.path.abspath(__file__))
# repo root is three levels up: .../QE Funding Agreement Queries/CountByMonthForPayment/<this file>
REPO_ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, REPO_ROOT)
from athena_hello_world import athena_query, confirm_month_ready, resolve_month  # noqa: E402

SQL_OF_RECORD = os.path.join(HERE, "Monthly-VolumneByQEByDataType.sql")


def to_int(v):
    try:
        return int(str(v).strip())
    except (ValueError, TypeError):
        return 0


def first_of_month(d):
    return date(d.year, d.month, 1)


def add_months(d, n):
    """Shift a first-of-month date by n months (n may be negative)."""
    total = (d.year * 12 + (d.month - 1)) + n
    return date(total // 12, (total % 12) + 1, 1)


def build_sql(template, start_month, end_month):
    """Return the query of record with ONLY the two config dates swapped."""
    sql = template
    sql, n1 = re.subn(
        r"DATE\s+'[^']*'\s+AS\s+start_month",
        f"DATE '{start_month.isoformat()}' AS start_month",
        sql,
        count=1,
    )
    sql, n2 = re.subn(
        r"DATE\s+'[^']*'\s+AS\s+end_month",
        f"DATE '{end_month.isoformat()}' AS end_month",
        sql,
        count=1,
    )
    if not (n1 == n2 == 1):
        raise RuntimeError(
            "Could not cleanly substitute start_month/end_month in the SQL of "
            f"record (start={n1}, end={n2}). The config block may have changed; "
            "aborting rather than running an altered query."
        )
    return sql


GITHUB_SQL_PATH = (
    r"SQLForS3InventoryOfPDR\QE Funding Agreement Queries\CountByMonthForPayment\Monthly-VolumneByQEByDataType.sql"
)
GITHUB_SQL_URL = (
    "https://github.com/rsxmjb234/SQLForS3InventoryOfPDR/blob/main/"
    "QE%20Funding%20Agreement%20Queries/CountByMonthForPayment/"
    "Monthly-VolumneByQEByDataType.sql"
)

AGREEMENT_LANGUAGE = (
    '"The total volume of data submitted is expected to remain consistent month to '
    "month. For purposes of performance monitoring, each QE will be required to submit, "
    "at a minimum the aggregate amount of data; NYeC will assess this using a rolling "
    "two-month average of submitted volume, by data type, as the 'baseline.' Beginning "
    "June 15th (and monthly thereafter), NYeC will inform each QE of its baseline. If, "
    "for a full calendar month, a QE's submitted volume is more than 10% below its "
    "baseline, and the variance is not attributable to expected changes (e.g., "
    "participant onboarding/offboarding or other agreed-upon adjustments), the variance "
    'will be considered a PDR outage."'
)


def volume_memo_text(month_str, rows):
    """Build the conclusion memo for the volume SLA for the target month."""
    y, m = (int(x) for x in month_str.split("-"))
    month_name = f"{calendar.month_name[m]}, {y}"

    # SCOPE: CCD ONLY for the SLA determination this month. We do not yet have
    # enough clean, stable data on Labs (recently onboarded) or TRN to measure
    # them effectively, so the pass/fail is based exclusively on CCD volume.
    #
    # BASELINE: September 2026 is EXCLUDED due to a PDR data anomaly. Instead of
    # the rolling 2-month average (which would include the anomalous September),
    # we use a fixed baseline = the average of JULY and AUGUST CCD volume, and
    # compare the target month against it. A QE fails if its target-month CCD
    # volume is more than 10% below that Jul/Aug average.
    base_month_1 = add_months(date(y, m, 1), -3)   # e.g. Oct target -> July
    base_month_2 = add_months(date(y, m, 1), -2)   # e.g. Oct target -> August
    bm1 = base_month_1.strftime("%Y-%m")
    bm2 = base_month_2.strftime("%Y-%m")
    bm1_name = calendar.month_name[base_month_1.month]
    bm2_name = calendar.month_name[base_month_2.month]

    def _ccd(qe, month):
        for r in rows:
            if r.get("qe") == qe and r.get("data_type") == "CCD" and r.get("month") == month:
                return to_int(r.get("doc_count"))
        return 0

    target_rows = [r for r in rows
                   if r.get("month") == month_str and r.get("data_type") == "CCD"]
    ccd_qes = sorted({r["qe"] for r in target_rows})

    assessed = []   # dicts: qe, target, baseline, pct, flag
    for qe in ccd_qes:
        baseline = round((_ccd(qe, bm1) + _ccd(qe, bm2)) / 2)
        target = _ccd(qe, month_str)
        if baseline <= 0:
            continue
        pct = round(100.0 * target / baseline)
        assessed.append({
            "qe": qe, "target": target, "baseline": baseline, "pct": pct,
            "flag": "YES" if target < baseline * 0.9 else "NO",
        })

    flagged = [a for a in assessed if a["flag"] == "YES"]
    passed = [a for a in assessed if a["flag"] == "NO"]
    flagged_qes = sorted(a["qe"] for a in flagged)

    if not assessed:
        conclusion = ("Conclusion: No determination could be made this month "
                      f"(no QE had usable {bm1_name}/{bm2_name} CCD baseline data).")
    elif flagged_qes:
        conclusion = ("Conclusion: These QEs' CCD volume dropped below SLA: "
                      + ", ".join(flagged_qes) + ".")
    else:
        conclusion = "Conclusion: No QE's CCD volume dropped below SLA."

    if not assessed:
        result_line = (
            f"No QE had usable {bm1_name}/{bm2_name} CCD volume to form a baseline, "
            "so no volume SLA determination can be made."
        )
    elif flagged:
        viol = "; ".join(f"{a['qe']} ({a['pct']}% of baseline)" for a in flagged)
        result_line = (
            f"The following QEs submitted October CCD volume more than 10% below their "
            f"{bm1_name}/{bm2_name} baseline and therefore did NOT meet the volume SLA "
            f"(treated as a PDR outage): {viol}. All other assessed QEs met the CCD "
            f"volume SLA."
        )
    else:
        qe_set = sorted(a["qe"] for a in passed)
        result_line = (
            f"All QEs PASSED: every assessed QE submitted CCD volume within 10% of its "
            f"{bm1_name}/{bm2_name} baseline. QE(s) assessed and passing: "
            f"{', '.join(qe_set)}."
        )

    # Backup data table: per QE, target vs Jul/Aug baseline.
    backup = _ccd_baseline_block(assessed, month_str, bm1_name, bm2_name)

    # Trend: doc_count per QE/data-type across every month in the window.
    trend = _monthly_trend_block(rows)

    return f"""For purposes of performance monitoring and contractual compliance, each QE's submitted data volume is assessed against a baseline. Per the funding agreement:

{AGREEMENT_LANGUAGE}

Scope for this month: CCD only. We do not yet have enough clean, stable history
to measure Labs or TRN effectively (Labs were only recently onboarded, and TRN
volume is not yet reliable for baseline comparison), so this month's SLA
determination is based exclusively on CCD volume. Labs and TRN are shown in the
trend data below for context only and are not part of the pass/fail.

Baseline for this month: September 2026 is EXCLUDED from the baseline due to a
known data anomaly in the PDR during that month (a bulk re-stamp of S3 objects
distorted September volume). Rather than the standard rolling 2-month average
(which would include the anomalous September), this month compares October CCD
volume against a fixed baseline = the average of {bm1_name} and {bm2_name} CCD
volume. A QE is below SLA if its October CCD volume is more than 10% below that
{bm1_name}/{bm2_name} average.

Result in {month_name} (CCD)

{conclusion}

{result_line}

Query that was used can be found in GitHub at the following path:

{GITHUB_SQL_PATH}

Direct link: {GITHUB_SQL_URL}

Backup data (October CCD volume vs the {bm1_name}/{bm2_name} baseline, by QE)
{backup}
Monthly trend (document count by QE and data type across the full window; note September is anomalous and excluded from the baseline):
{trend}"""


def _ccd_baseline_block(assessed, target_month, bm1_name, bm2_name):
    """Render October CCD volume vs the Jul/Aug baseline, per QE."""
    if not assessed:
        return "No QE had a usable baseline.\n"
    header = ["qe", f"{target_month}_ccd", f"baseline_{bm1_name[:3]}_{bm2_name[:3]}_avg",
              "pct_of_baseline", "below_10pct"]
    lines = [" | ".join(header), "-" * 72]
    for a in sorted(assessed, key=lambda x: x["qe"]):
        lines.append(" | ".join([
            a["qe"], f"{a['target']:,}", f"{a['baseline']:,}", f"{a['pct']}%", a["flag"],
        ]))
    return "\n".join(lines) + "\n"


def _volume_backup_block(rows, max_rows=100):
    if not rows:
        return "No rows returned for the target month.\n"
    cols = ["qe", "data_type", "doc_count", "rolling_2mo_avg",
            "pct_of_baseline", "below_10pct_flag"]
    present = [c for c in cols if c in rows[0]]
    lines = [" | ".join(present), "-" * 72]
    for r in sorted(rows, key=lambda x: (x.get("qe", ""), x.get("data_type", "")))[:max_rows]:
        lines.append(" | ".join(str(r.get(c, "")) for c in present))
    return "\n".join(lines) + "\n"


def _monthly_trend_block(rows):
    """Pivot: one line per QE/data-type, doc_count for each month in the window."""
    if not rows:
        return "No rows returned.\n"
    months = sorted({r["month"] for r in rows if r.get("month")})
    # key = (qe, data_type) -> {month: doc_count}
    table = {}
    for r in rows:
        key = (r.get("qe", ""), r.get("data_type", ""))
        table.setdefault(key, {})[r.get("month")] = r.get("doc_count", "")
    header = ["qe/data_type"] + months
    lines = [" | ".join(header), "-" * 72]
    for key in sorted(table):
        label = f"{key[0]}/{key[1]}"
        cells = [str(table[key].get(mo, "0")) for mo in months]
        lines.append(" | ".join([label] + cells))
    return "\n".join(lines) + "\n"


def write_csv(rows, out_path):
    if not rows:
        # Still write a header-only file so the run is visibly complete.
        cols = ["month", "qe", "data_type", "doc_count", "rolling_2mo_avg",
                "pct_of_baseline", "below_10pct_flag"]
    else:
        cols = list(rows[0].keys())
    with open(out_path, "w", newline="", encoding="utf-8") as fh:
        w = csvmod.DictWriter(fh, fieldnames=cols)
        w.writeheader()
        for r in rows:
            w.writerow(r)


def main():
    ap = argparse.ArgumentParser(
        description="Monthly QE volume / baseline report (funding agreement)")
    ap.add_argument("--month", default=None,
                    help="Target month to assess: YYYY-MM or a bare month number "
                         "(1-12). If omitted, you'll be prompted (default = last month).")
    ap.add_argument("--lead-months", type=int, default=4,
                    help="How many months before the target to include. The rolling "
                         "baseline itself uses only the 2 prior months, but including "
                         "more months gives trend context in the backup data (default 4).")
    ap.add_argument("--out", default=None, help="Optional output .csv path")
    args = ap.parse_args()

    if not os.path.exists(SQL_OF_RECORD):
        print(f"SQL of record not found: {SQL_OF_RECORD}", file=sys.stderr)
        return 2

    with open(SQL_OF_RECORD, "r", encoding="utf-8") as fh:
        template = fh.read()

    args.month = resolve_month(args.month)

    if not confirm_month_ready(args.month):
        return 1

    target = date(int(args.month.split("-")[0]), int(args.month.split("-")[1]), 1)
    start_month = add_months(target, -args.lead_months)
    end_month = target  # query's config uses first-of-month for both bounds

    print(f"Target month : {args.month}")
    print(f"Window       : {start_month.isoformat()} through {end_month.isoformat()} "
          f"(includes {args.lead_months} lead month(s) for the rolling baseline)")
    print(f"SQL of record: {SQL_OF_RECORD}")

    sql = build_sql(template, start_month, end_month)
    print("\nRunning monthly-volume query...")
    rows, scanned = athena_query(sql)
    print(f"  {len(rows)} row(s); scanned {scanned/1024/1024/1024:.2f} GB")

    # Raw backup CSV (the full window, all months/QEs/data types).
    csv_out = os.path.join(HERE, f"Monthly_Volume_By_QE_{args.month}.csv")
    write_csv(rows, csv_out)
    print(f"Wrote backup CSV: {csv_out}")

    # Conclusion memo, filename format:
    #   "MM-YYYY MMM Review of Data Volume Gaps in Data for PDR.txt"
    y, m = (int(x) for x in args.month.split("-"))
    mmm = calendar.month_abbr[m]
    memo_name = f"{m:02d}-{y} {mmm} Review of Data Volume Gaps in Data for PDR.txt"
    memo_out = args.out or os.path.join(HERE, memo_name)
    text = volume_memo_text(args.month, rows)
    with open(memo_out, "w", encoding="utf-8") as fh:
        fh.write(text)
    print("\n" + "=" * 70)
    print(text)
    print("=" * 70)
    print(f"\nWrote memo: {memo_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
