"""
Generate the monthly contracting-team language for the PDR 240-minute outage goal.

HOW IT WORKS
------------
- The QUERY OF RECORD is the committed SQL file (do NOT edit it):
      QE Funding Agreement Queries/QEFundingAgreement240Goal/measure240minbyqe-date-range.sql
- This script READS that .sql file and changes ONLY the dates (start_day/end_day)
  for the month you ask for. For the sanity-check pass it also changes ONLY the
  outage_threshold_minutes value (240 -> 30), which the query itself documents
  as a configurable knob.
- It runs both passes against Athena (reusing athena_hello_world.athena_query),
  then prints / writes the contracting language, filling in the real result.

USAGE
-----
  python generate_240_contract_language.py --month 2026-10
  python generate_240_contract_language.py --month 2026-10 --out memo_2026-10.txt

Requires valid AWS credentials (see athena_hello_world.py --check).
"""

import argparse
import calendar
import os
import re
import sys
from datetime import date

HERE = os.path.dirname(os.path.abspath(__file__))
# Repo root is three levels up: .../QE Funding Agreement Queries/QEFundingAgreement240Goal/<this file>
REPO_ROOT = os.path.dirname(os.path.dirname(HERE))

# Import the reusable Athena runner from the hello-world helper at repo root.
sys.path.insert(0, REPO_ROOT)
from athena_hello_world import athena_query  # noqa: E402

# The query of record lives alongside this script.
SQL_OF_RECORD = os.path.join(HERE, "measure240minbyqe-date-range.sql")
# Full repo-relative path to the query of record, plus a clickable GitHub URL,
# so anyone left with the memo can locate the exact query.
GITHUB_REPO = "rsxmjb234/SQLForS3InventoryOfPDR"
GITHUB_SQL_PATH = (
    r"SQLForS3InventoryOfPDR\QE Funding Agreement Queries\QEFundingAgreement240Goal\measure240minbyqe-date-range.sql"
)
GITHUB_SQL_URL = (
    "https://github.com/rsxmjb234/SQLForS3InventoryOfPDR/blob/main/"
    "QE%20Funding%20Agreement%20Queries/QEFundingAgreement240Goal/"
    "measure240minbyqe-date-range.sql"
)


def month_bounds(month_str):
    """'2026-10' -> (date(2026,10,1), date(2026,10,31))."""
    year, mon = (int(x) for x in month_str.split("-"))
    last = calendar.monthrange(year, mon)[1]
    return date(year, mon, 1), date(year, mon, last)


def build_sql(template, start_day, end_day, threshold_minutes):
    """Return the query of record with ONLY the dates and threshold swapped.

    Nothing else in the SQL is touched. We target the three lines inside the
    config CTE by their fixed suffixes (AS start_day / AS end_day /
    AS outage_threshold_minutes).
    """
    sql = template

    # start_day: replace the whole assignment expression (the text after SELECT,
    # up to 'AS start_day'). The expression may span commas, so match minimally
    # but across newlines up to the 'AS start_day' marker.
    sql, n1 = re.subn(
        r"SELECT\s*\n.*?AS\s+start_day",
        f"SELECT\n\t\tDATE '{start_day.isoformat()}' AS start_day",
        sql,
        count=1,
        flags=re.DOTALL,
    )
    # end_day: the original expression (date_add(... current_timestamp ...)) can
    # contain its own commas, so match everything from just after the start_day
    # comma up to 'AS end_day'.
    sql, n2 = re.subn(
        r"(AS\s+start_day\s*,\s*\n).*?AS\s+end_day",
        rf"\1\t\tDATE '{end_day.isoformat()}' AS end_day",
        sql,
        count=1,
        flags=re.DOTALL,
    )
    # outage_threshold_minutes: just the number.
    sql, n3 = re.subn(
        r"\d+\s+AS\s+outage_threshold_minutes",
        f"{threshold_minutes} AS outage_threshold_minutes",
        sql,
        count=1,
    )

    if not (n1 == n2 == n3 == 1):
        raise RuntimeError(
            "Could not cleanly substitute dates/threshold in the SQL of record "
            f"(start={n1}, end={n2}, threshold={n3}). The config block may have "
            "changed; aborting rather than running an altered query."
        )
    return sql


def run_pass(template, start_day, end_day, threshold):
    sql = build_sql(template, start_day, end_day, threshold)
    rows, scanned = athena_query(sql)
    qes_with_gaps = sorted({r["qe"] for r in rows if r.get("qe")})
    return rows, qes_with_gaps, scanned


def memo_text(month_str, result_240, qes_240, result_30, qes_30):
    year, mon = (int(x) for x in month_str.split("-"))
    month_name = f"{calendar.month_name[mon]}, {year}"

    if qes_240:
        qe_list = ", ".join(qes_240)
        result_line = (
            f"The following QE(s) had at least one 240 minute gap: {qe_list} "
            f"({len(result_240)} outage event(s) total)."
        )
    else:
        result_line = "No QE had a 240 minute gap"

    if qes_30:
        sanity_line = (
            "We also sanity check by setting query to 30 minutes and observe that "
            f"gaps in data do appear ({len(result_30)} gap event(s) at the 30 minute "
            f"threshold across {len(qes_30)} QE(s))."
        )
    else:
        sanity_line = (
            "We also sanity check by setting query to 30 minutes; note that at the "
            "30 minute threshold NO gaps appeared, which is unexpected and may warrant "
            "a closer look at the data."
        )

    return f"""For purposes of performance monitoring and contractual compliance, failure to submit any required data type to the Primary Document Repository (PDR), (E.g. CCD, TRN, or ORU) for a continuous 240-minute period shall constitute an outage event.

Result in {month_name}

{result_line}

Query that was used can be found in GitHub at the following path:

{GITHUB_SQL_PATH}

Direct link: {GITHUB_SQL_URL}

{sanity_line}
"""


def main():
    ap = argparse.ArgumentParser(description="Monthly 240-minute PDR contract language")
    ap.add_argument("--month", required=True, help="Month to report, e.g. 2026-10")
    ap.add_argument("--out", default=None, help="Optional output .txt path")
    ap.add_argument("--sanity-threshold", type=int, default=30,
                    help="Minutes for the sanity-check pass (default 30)")
    args = ap.parse_args()

    if not os.path.exists(SQL_OF_RECORD):
        print(f"SQL of record not found: {SQL_OF_RECORD}", file=sys.stderr)
        return 2

    with open(SQL_OF_RECORD, "r", encoding="utf-8") as fh:
        template = fh.read()

    start_day, end_day = month_bounds(args.month)
    print(f"Reporting month : {args.month}  ({start_day} to {end_day})")
    print(f"SQL of record   : {SQL_OF_RECORD}")

    print("\nRunning 240-minute compliance pass...")
    rows240, qes240, scan240 = run_pass(template, start_day, end_day, 240)
    print(f"  {len(rows240)} outage event(s); scanned {scan240/1024/1024/1024:.2f} GB")

    print(f"\nRunning {args.sanity_threshold}-minute sanity-check pass...")
    rows30, qes30, scan30 = run_pass(template, start_day, end_day, args.sanity_threshold)
    print(f"  {len(rows30)} gap event(s); scanned {scan30/1024/1024/1024:.2f} GB")

    text = memo_text(args.month, rows240, qes240, rows30, qes30)
    print("\n" + "=" * 70)
    print(text)
    print("=" * 70)

    out = args.out or os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        f"240_contract_language_{args.month}.txt",
    )
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(text)
    print(f"\nWrote: {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
