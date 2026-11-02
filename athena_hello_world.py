"""
Athena "hello world" — run a simple SELECT against the same database the PDR
SQL files use (pdr_inventory) and print the rows.

Prereqs:
  * boto3 installed (pip install boto3)  -- already done
  * Valid AWS credentials for the PDR profile. These are TEMPORARY and expire;
    refresh them the same way you did last week (your AWS access portal /
    `aws login`) before running. If you see "ExpiredToken", that's all this is.

Usage:
  python athena_hello_world.py
  python athena_hello_world.py --sql "SELECT 1 AS hello"
  python athena_hello_world.py --output s3://your-athena-results-bucket/path/

Notes:
  * Athena needs somewhere to write query results in S3. If your workgroup
    already has a result location configured, you don't need --output. If you
    get an error about an output/result location, pass --output s3://.../.
"""

import argparse
import sys
import time

import boto3
from botocore.exceptions import ClientError, NoCredentialsError

# ---- Defaults (edit if your environment differs) -------------------------
PROFILE = "220065406231_pdr-nyec-program-team-PROD"   # profile in ~/.aws/config
REGION = "us-east-1"
DATABASE = "pdr_inventory"                             # same DB as the .sql files (AwsDataCatalog)
WORKGROUP = "primary"                                  # change if you use another
OUTPUT = "s3://pdr-nyec-local/MichaelAthenaResults/"   # where Athena writes results
DEFAULT_SQL = (
    "SELECT * FROM pdr_inventory.lookup_hospital_assigning_authorities LIMIT 5"
)
POLL_SECONDS = 2.0
TIMEOUT_SECONDS = 600
# --------------------------------------------------------------------------


def run_query(client, sql, database, workgroup, output):
    kwargs = {
        "QueryString": sql,
        "QueryExecutionContext": {"Database": database},
        "WorkGroup": workgroup,
    }
    if output:
        kwargs["ResultConfiguration"] = {"OutputLocation": output}
    resp = client.start_query_execution(**kwargs)
    return resp["QueryExecutionId"]


def wait_for(client, qid):
    deadline = time.time() + TIMEOUT_SECONDS
    while True:
        ex = client.get_query_execution(QueryExecutionId=qid)["QueryExecution"]
        state = ex["Status"]["State"]
        if state in ("SUCCEEDED", "FAILED", "CANCELLED"):
            return state, ex
        if time.time() > deadline:
            return "TIMEOUT", ex
        time.sleep(POLL_SECONDS)


def fetch_rows(client, qid):
    """Return query results as a list of dicts (header row becomes keys)."""
    paginator = client.get_paginator("get_query_results")
    header = None
    out = []
    for page in paginator.paginate(QueryExecutionId=qid):
        for r in page["ResultSet"]["Rows"]:
            values = [c.get("VarCharValue", "") for c in r["Data"]]
            if header is None:
                header = values
            else:
                out.append(dict(zip(header, values)))
    return out


def athena_query(sql, *, profile=PROFILE, region=REGION, database=DATABASE,
                 workgroup=WORKGROUP, output=OUTPUT):
    """Run a query and return (rows_as_dicts, bytes_scanned). Raises on failure.

    Reusable entry point for other scripts (e.g. the contract-language memo).
    """
    session = boto3.Session(profile_name=profile, region_name=region)
    client = session.client("athena")
    qid = run_query(client, sql, database, workgroup, output)
    state, ex = wait_for(client, qid)
    if state != "SUCCEEDED":
        reason = ex.get("Status", {}).get("StateChangeReason", "")
        raise RuntimeError(f"Athena query {state}: {reason}")
    scanned = ex.get("Statistics", {}).get("DataScannedInBytes", 0)
    return fetch_rows(client, qid), scanned


def print_results(client, qid):
    paginator = client.get_paginator("get_query_results")
    first = True
    row_count = 0
    for page in paginator.paginate(QueryExecutionId=qid):
        rows = page["ResultSet"]["Rows"]
        for r in rows:
            values = [c.get("VarCharValue", "") for c in r["Data"]]
            if first:
                print(" | ".join(values))
                print("-" * 60)
                first = False
            else:
                print(" | ".join(values))
                row_count += 1
    print(f"\n({row_count} data row(s))")


def main():
    ap = argparse.ArgumentParser(description="Athena hello-world query")
    ap.add_argument("--sql", default=DEFAULT_SQL, help="SQL to run")
    ap.add_argument("--database", default=DATABASE)
    ap.add_argument("--workgroup", default=WORKGROUP)
    ap.add_argument("--region", default=REGION)
    ap.add_argument("--profile", default=PROFILE)
    ap.add_argument("--output", default=OUTPUT,
                    help="S3 results location, e.g. s3://bucket/prefix/")
    ap.add_argument("--check", action="store_true",
                    help="Just check who you're logged in as (sts get-caller-identity) and exit")
    args = ap.parse_args()

    try:
        session = boto3.Session(profile_name=args.profile, region_name=args.region)
        client = session.client("athena")
    except Exception as e:
        print(f"Could not create Athena client: {e}", file=sys.stderr)
        return 2

    if args.check:
        try:
            ident = session.client("sts").get_caller_identity()
            print("Logged in OK")
            print(f"  Account : {ident['Account']}")
            print(f"  ARN     : {ident['Arn']}")
            return 0
        except (ClientError, NoCredentialsError) as e:
            msg = str(e)
            print(f"Not logged in: {msg}", file=sys.stderr)
            if "ExpiredToken" in msg or "expired" in msg.lower():
                print("-> Your AWS session has expired. Refresh the keys in "
                      "~/.aws/config and rerun.", file=sys.stderr)
            return 3

    print(f"Profile : {args.profile}")
    print(f"Region  : {args.region}")
    print(f"Database: {args.database}")
    print(f"SQL     : {args.sql}\n")

    try:
        qid = run_query(client, args.sql, args.database, args.workgroup, args.output)
    except NoCredentialsError:
        print("No AWS credentials found. Refresh your login and try again.", file=sys.stderr)
        return 3
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code", "")
        msg = e.response.get("Error", {}).get("Message", str(e))
        print(f"Athena error ({code}): {msg}", file=sys.stderr)
        if "ExpiredToken" in code or "expired" in msg.lower():
            print("-> Your AWS session has expired. Refresh your login and rerun.",
                  file=sys.stderr)
        if "output location" in msg.lower() or "ResultConfiguration" in msg:
            print("-> Pass an S3 results location with --output s3://bucket/prefix/",
                  file=sys.stderr)
        return 4

    print(f"Query submitted: {qid}  (polling...)")
    state, ex = wait_for(client, qid)

    if state != "SUCCEEDED":
        reason = ex.get("Status", {}).get("StateChangeReason", "")
        print(f"Query {state}. {reason}", file=sys.stderr)
        return 5

    scanned = ex.get("Statistics", {}).get("DataScannedInBytes", 0)
    print(f"SUCCEEDED (scanned {scanned/1024/1024:.2f} MB)\n")
    print_results(client, qid)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
