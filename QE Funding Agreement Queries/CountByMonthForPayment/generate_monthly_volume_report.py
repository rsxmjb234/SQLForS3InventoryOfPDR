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

    target_rows = [r for r in rows if r.get("month") == month_str]
    # Only rows with a usable baseline can be assessed.
    assessable = [r for r in target_rows
                  if r.get("rolling_2mo_avg") not in (None, "", "0")
                  and r.get("below_10pct_flag") in ("YES", "NO")]
    flagged = [r for r in assessable if r.get("below_10pct_flag") == "YES"]
    passed = [r for r in assessable if r.get("below_10pct_flag") == "NO"]
    no_baseline = [r for r in target_rows if r not in assessable]

    # One-line headline conclusion (the "bottom line" for the memo).
    flagged_qes = sorted({r["qe"] for r in flagged})
    if not assessable:
        conclusion = ("Conclusion: No determination could be made this month "
                      "(no QE had a usable rolling baseline).")
    elif flagged_qes:
        conclusion = ("Conclusion: These QEs' volume dropped below SLA: "
                      + ", ".join(flagged_qes) + ".")
    else:
        conclusion = "Conclusion: No QE's volume dropped below SLA."

    if not assessable:
        result_line = (
            "No QE/data-type combination for this month had a usable rolling baseline, "
            "so no volume SLA determination can be made. (The rolling 2-month baseline "
            "needs two prior months of data.)"
        )
    elif flagged:
        viol = "; ".join(
            f"{r['qe']} / {r['data_type']} ({r['pct_of_baseline']}% of baseline)"
            for r in flagged
        )
        qe_set = sorted({r["qe"] for r in flagged})
        result_line = (
            f"The following QE/data-type combinations were more than 10% below baseline "
            f"and therefore did NOT meet the volume SLA (treated as a PDR outage): {viol}. "
            f"QE(s) affected: {', '.join(qe_set)}. All other assessed QE/data-type "
            f"combinations met the volume SLA."
        )
    else:
        qe_set = sorted({r["qe"] for r in passed})
        result_line = (
            f"All QEs PASSED: every assessed QE/data-type combination submitted volume "
            f"within 10% of its rolling 2-month baseline, so no QE violated the volume SLA "
            f"this month. QE(s) assessed and passing: {', '.join(qe_set)}."
        )

    # Backup data table: per QE/data-type for the target month.
    backup = _volume_backup_block(assessable + no_baseline)

    # Trend: doc_count per QE/data-type across every month in the window, so a
    # multi-month decline is visible (the 10% rule only compares to 2 prior months).
    trend = _monthly_trend_block(rows)

    nb_note = ""
    if no_baseline:
        combos = ", ".join(f"{r['qe']}/{r['data_type']}" for r in no_baseline)
        nb_note = (
            f"\nNote: the following had no usable baseline this month and were not "
            f"assessed: {combos}.\n"
        )

    return f"""For purposes of performance monitoring and contractual compliance, each QE's submitted data volume is assessed against a rolling two-month average baseline, by data type. Per the funding agreement:

{AGREEMENT_LANGUAGE}

Result in {month_name}

{conclusion}

{result_line}
{nb_note}
Query that was used can be found in GitHub at the following path:

{GITHUB_SQL_PATH}

Direct link: {GITHUB_SQL_URL}

Backup data (target month {month_str}: volume vs rolling 2-month baseline by QE and data type)
{backup}
Monthly trend (document count by QE and data type across the full window - lets you see whether volume declined over several months, which the 2-month baseline alone cannot show):
{trend}"""


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
