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
from athena_hello_world import athena_query, confirm_month_ready, resolve_month  # noqa: E402

# The query of record lives alongside this script.
SQL_OF_RECORD = os.path.join(HERE, "measure240minbyqe-date-range.sql")
# Full repo-relative path to the query of record, plus a clickable GitHub URL,
# so anyone left with the memo can locate the exact query.
# If the sanity-check pass finds fewer than this many gaps, escalate to a finer
# threshold (per the rule: <5 gaps at 30 min -> drop to 15 min).
MIN_SANITY_GAPS = 5

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


def memo_text(month_str, result_240, qes_240, result_30, qes_30, sanity_minutes=30):
    year, mon = (int(x) for x in month_str.split("-"))
    month_name = f"{calendar.month_name[mon]}, {year}"

    if qes_240:
        qe_list = ", ".join(qes_240)
        result_line = (
            f"The following QE(s) did NOT meet the 240 minute SLA (had at least one "
            f"continuous 240+ minute gap): {qe_list}. All other QEs met the SLA."
        )
    else:
        result_line = "No QE had a 240 minute gap. All QEs met the 240 minute SLA."

    sanity_line = (
        f"We also sanity check by setting query to {sanity_minutes} minutes and observe "
        f"that gaps in data do appear. This confirms the outage-detection logic is working: "
        f"when the threshold is lowered, shorter gaps are correctly surfaced."
        if qes_30 else
        f"We also sanity check by setting query to {sanity_minutes} minutes; note that at the "
        f"{sanity_minutes} minute threshold NO gaps appeared, which is unexpected and may "
        f"warrant a closer look at the data."
    )

    validated_line = (
        "The query was also validated pre-go-live: a QE did have a >240 minute gap that the "
        "query correctly detected, confirming the measure flags true outages."
    )

    # Backup data: the actual gap rows at the sanity threshold, proving the logic works.
    evidence = _gap_evidence_block(result_30, sanity_minutes)

    return f"""For purposes of performance monitoring and contractual compliance, failure to submit any required data type to the Primary Document Repository (PDR), (E.g. CCD, TRN, or ORU) for a continuous 240-minute period shall constitute an outage event.

Result in {month_name}

{result_line}

Query that was used can be found in GitHub at the following path:

{GITHUB_SQL_PATH}

Direct link: {GITHUB_SQL_URL}

{sanity_line}

{validated_line}

Backup data
-----------
{evidence}"""


def _gap_evidence_block(rows, sanity_minutes, max_rows=25):
    """Render the gap rows (at the threshold used) as a readable table."""
    if not rows:
        return (f"{sanity_minutes}-minute sanity-check detail: no gap events were returned.\n")

    cols = ["day", "qe", "outage_start_ts", "outage_end_ts", "gap_minutes", "gap_type"]
    present = [c for c in cols if c in rows[0]]

    lines = [f"{sanity_minutes}-minute sanity-check detail (evidence that gaps are detected):", ""]
    lines.append(" | ".join(present))
    lines.append("-" * 72)
    for r in rows[:max_rows]:
        lines.append(" | ".join(str(r.get(c, "")) for c in present))
    if len(rows) > max_rows:
        lines.append(f"... ({len(rows) - max_rows} more gap event(s) not shown)")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(description="Monthly 240-minute PDR contract language")
    ap.add_argument("--month", default=None,
                    help="Month to report: YYYY-MM or a bare month number (1-12). "
                         "If omitted, you'll be prompted (default = last month).")
    ap.add_argument("--out", default=None, help="Optional output .txt path")
    ap.add_argument("--sanity-threshold", type=int, default=30,
                    help="Minutes for the first sanity-check pass (default 30)")
    ap.add_argument("--escalate-threshold", type=int, default=15,
                    help="If the first sanity pass finds fewer than "
                         f"{MIN_SANITY_GAPS} gaps, re-run at this finer threshold "
                         "(default 15). Set to 0 to disable escalation.")
    args = ap.parse_args()

    if not os.path.exists(SQL_OF_RECORD):
        print(f"SQL of record not found: {SQL_OF_RECORD}", file=sys.stderr)
        return 2

    with open(SQL_OF_RECORD, "r", encoding="utf-8") as fh:
        template = fh.read()

    args.month = resolve_month(args.month)

    if not confirm_month_ready(args.month):
        return 1

    start_day, end_day = month_bounds(args.month)
    print(f"Reporting month : {args.month}  ({start_day} to {end_day})")
    print(f"SQL of record   : {SQL_OF_RECORD}")

    print("\nRunning 240-minute compliance pass...")
    rows240, qes240, scan240 = run_pass(template, start_day, end_day, 240)
    print(f"  {len(rows240)} outage event(s); scanned {scan240/1024/1024/1024:.2f} GB")

    # Sanity check. If the first sanity threshold finds too few gaps to be a
    # convincing check (fewer than MIN_SANITY_GAPS), drop to a finer threshold
    # so gaps clearly appear.
    sanity_threshold = args.sanity_threshold
    print(f"\nRunning {sanity_threshold}-minute sanity-check pass...")
    sanity_rows, sanity_qes, sanity_scan = run_pass(template, start_day, end_day, sanity_threshold)
    print(f"  {len(sanity_rows)} gap event(s); scanned {sanity_scan/1024/1024/1024:.2f} GB")

    if len(sanity_rows) < MIN_SANITY_GAPS and args.escalate_threshold:
        finer = args.escalate_threshold
        print(f"  Fewer than {MIN_SANITY_GAPS} gaps found; escalating sanity check "
              f"to {finer} minutes...")
        sanity_threshold = finer
        sanity_rows, sanity_qes, sanity_scan = run_pass(template, start_day, end_day, finer)
        print(f"  {len(sanity_rows)} gap event(s) at {finer} min; "
              f"scanned {sanity_scan/1024/1024/1024:.2f} GB")

    text = memo_text(args.month, rows240, qes240, sanity_rows, sanity_qes, sanity_threshold)
    print("\n" + "=" * 70)
    print(text)
    print("=" * 70)

    # Filename format: "MM-YYYY MMM Review of 240 Minute Gaps in Data for PDR.txt"
    y, m = (int(x) for x in args.month.split("-"))
    mmm = calendar.month_abbr[m]
    default_name = f"{m:02d}-{y} {mmm} Review of 240 Minute Gaps in Data for PDR.txt"
    out = args.out or os.path.join(os.path.dirname(os.path.abspath(__file__)), default_name)
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(text)
    print(f"\nWrote: {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
