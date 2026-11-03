"""
Run BOTH monthly contract memos for one month, in sequence:
  1. 240-minute gap SLA memo
  2. Data volume SLA memo (+ backup CSV)

=============================================================================
HOW TO RUN  (copy one of these into the terminal from the repo root):

  python run_monthly_contract_memos.py --month 10
  python run_monthly_contract_memos.py --month 2026-10

--month accepts a bare month number (1-12) or YYYY-MM. A bare number resolves
to the most recent occurrence at or before the current month (so in January,
"12" means last December). If you omit --month entirely it defaults to LAST
month. No prompts - edit the command above before running if you want a
different month.

Prereq: valid AWS credentials for account 220065406231. Check with:
  python athena_hello_world.py --check
=============================================================================
"""

import argparse
import subprocess
import sys
import os

HERE = os.path.dirname(os.path.abspath(__file__))

SCRIPTS = [
    ("240-minute gap SLA memo",
     os.path.join(HERE, "QE Funding Agreement Queries", "QEFundingAgreement240Goal",
                  "generate_240_contract_language.py")),
    ("Data volume SLA memo",
     os.path.join(HERE, "QE Funding Agreement Queries", "CountByMonthForPayment",
                  "generate_monthly_volume_report.py")),
]


def main():
    ap = argparse.ArgumentParser(description="Run both monthly contract memos for one month")
    ap.add_argument("--month", default=None,
                    help="YYYY-MM or a bare month number (1-12). Omit for last month.")
    args = ap.parse_args()

    # Pass --month through only if given; otherwise let each script default to last month.
    passthrough = ["--month", args.month] if args.month else []

    overall_ok = True
    for label, path in SCRIPTS:
        print("\n" + "=" * 72)
        print(f"RUNNING: {label}")
        print("=" * 72)
        if not os.path.exists(path):
            print(f"  SKIPPED - script not found: {path}", file=sys.stderr)
            overall_ok = False
            continue
        # Pre-answer any y/N inventory-readiness prompt with 'y' via stdin.
        result = subprocess.run(
            [sys.executable, path] + passthrough,
            input="y\n", text=True, cwd=HERE,
        )
        if result.returncode != 0:
            print(f"  {label} FAILED (exit {result.returncode}).", file=sys.stderr)
            overall_ok = False

    print("\n" + "=" * 72)
    if overall_ok:
        print("DONE: both memos generated.")
    else:
        print("FINISHED WITH ERRORS: see messages above.")
    print("=" * 72)
    return 0 if overall_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
