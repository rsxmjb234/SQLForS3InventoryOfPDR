"""
Run the Bronx CCD source drilldown and print the ranked result + write a CSV.

HOW TO RUN (from the repo root):
  python "QE Funding Agreement Queries/CountByMonthForPayment/run_bronx_drilldown.py"

Edit the SQL file (Bronx-CCD-SourceDrilldown-Aug-vs-Oct.sql) to change QE/months.
Requires valid AWS creds (python athena_hello_world.py --check).
"""

import os
import sys
import csv as csvmod

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, REPO_ROOT)
from athena_hello_world import athena_query  # noqa: E402

SQL_FILE = os.path.join(HERE, "Bronx-CCD-SourceDrilldown-Aug-vs-Oct.sql")
COLS = ["assigning_authority", "verato_match", "ccd_month_a", "ccd_month_b",
        "change_abs", "pct_change", "status"]


def main():
    sql = open(SQL_FILE, encoding="utf-8-sig").read()
    print(f"Running: {os.path.basename(SQL_FILE)}")
    rows, scanned = athena_query(sql)
    print(f"{len(rows)} rows, scanned {scanned/1024/1024/1024:.2f} GB\n")

    present = [c for c in COLS if rows and c in rows[0]]
    print(" | ".join(present))
    print("-" * 80)
    for r in rows:
        print(" | ".join(str(r.get(c, "")) for c in present))

    out = os.path.join(HERE, "Bronx-CCD-SourceDrilldown-Aug-vs-Oct-results.csv")
    with open(out, "w", newline="", encoding="utf-8") as fh:
        w = csvmod.DictWriter(fh, fieldnames=(rows[0].keys() if rows else COLS))
        w.writeheader()
        for r in rows:
            w.writerow(r)
    print(f"\nWrote: {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
