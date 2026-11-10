"""
FixSFDCExport.py  -  turn a raw Salesforce (SFDC) hospital export into the corrected roster file.

THE JOB (two fixes, applied until the same fixes are made in Salesforce itself)
  1. HEC CODE FIX   HealtheConnections moved from numeric assigning-authority codes
                    (1025, 1722, ...) to named codes (UPSTATE, GUTHRIE, ...) around
                    March 30, 2026, but Salesforce still lists the numbers. For every row
                    with QE Name = HealtheConnections the legacy code is replaced using
                    ShowingHECOldAndNewAANames.csv (column D old -> column E new).
  2. SPARCS SCALE   Salesforce does not carry the SPARCS size of a hospital. The job adds
                    SCALER_SIZE (1 = smallest .. 10 = largest tier) to every row, looked up
                    by NYS-Facility ID in SPARCSScalerByFacility.csv.
Every other value in the export is left exactly as it came.

HOW TO REFRESH WHEN NEW SFDC DATA ARRIVES
  1. Save the new export in 1-Input-Data as   SFDC-export-RAW-<date>.csv
     (with or without a SCALER_SIZE column; the newest SFDC-export-RAW*.csv is used).
  2. Dry run  - writes the corrected file + logs locally, uploads nothing:
         python 4-Scripts/FixSFDCExport.py
  3. Read the summary and the two logs in 3-Results (see below), then replace the file in S3:
         python 4-Scripts/FixSFDCExport.py --upload
  4. Re-run the report SQL in 2-SQL (it reads the roster table from that S3 file).
  Keep the lookups current:
     - SPARCSScalerByFacility.csv   add or edit a line when SPARCS sizes change or a new
                                    hospital appears (see the "without SPARCS scale" log).
     - ShowingHECOldAndNewAANames.csv   replace with HEC's latest lookup when they send one.

WHAT IT WRITES
  1-Input-Data/AA Code Report_with_SCALER_SIZE.csv                 the corrected roster (18 columns,
                                                                    the layout the Athena table expects)
  3-Results/results-HEC-code-replacements-in-SFDC-export.csv       one line per HEC row changed
  3-Results/results-SFDC-hospitals-without-SPARCS-scale.csv        hospitals the lookup has no size for
                                                                    (they get no SCALER_SIZE, so the
                                                                    report leaves them out)

SAFETY
  - Dry run by default.  --upload first checks whether S3 already holds this exact file (then
    nothing is uploaded).  Otherwise it copies WHATEVER IS IN S3 NOW to a backup OUTSIDE the
    table folder (the Athena table reads every file in its folder, and the bucket has no
    versioning, so this backup is the way back), then replaces the file, then verifies
    size and checksum.
  - The corrected file must have exactly the 18 columns the Athena table expects, or the job
    stops before writing anything.
  - Non-HEC rows are never changed except for the SCALER_SIZE column.
To undo an upload: copy the backup object printed by --upload back over the roster key.
"""
import argparse
import csv
import datetime
import glob
import hashlib
import io
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent          # the analysis folder

HEC_QE = "HealtheConnections"
BUCKET = "pdr-nyec-local"
KEY = "Lookup-Hospital assigning Authorities/AA Code Report_with_SCALER_SIZE.csv"
BACKUP_PREFIX = "Lookup-Hospital-assigning-Authorities-BACKUPS/"   # NOT inside the table folder
PROFILE = "220065406231_pdr-nyec-program-team-PROD"
REGION = "us-east-1"

# The columns of pdr_inventory.lookup_hospital_assigning_authorities, in order.
EXPECTED_HEADER = [
    "NYS-Facility ID", "SHIN-NY ID", "Organization Status", "QE Participation Status", "Participating",
    "Organization Type", "Organization Description", "Organization Name", "QE Name", "Record Type", "Code",
    "Code Status", "Code Deactivation Date", "Code Level", "Code Level Description", "OID Feed Type",
    "Code Notes", "SCALER_SIZE",
]


def read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def parse(raw):
    rows = list(csv.reader(io.StringIO(raw.decode("utf-8-sig"), newline="")))
    return rows[0], rows[1:]


def serialize(header, rows):
    buf = io.StringIO(newline="")
    w = csv.writer(buf, lineterminator="\r\n")           # the export uses CRLF line endings
    w.writerow(header)
    w.writerows(rows)
    return buf.getvalue().encode("utf-8")


def load_hec_lookup(path):
    """old code -> list of (new code, active_flag), in file order, no duplicates."""
    out = {}
    with open(path, newline="", encoding="utf-8-sig") as f:
        for r in csv.DictReader(f):
            old = (r.get("Data Source Key") or "").strip()
            new = (r.get("Organization ID") or "").strip()
            active = (r.get("Active") or "").strip()
            if not old or not new:
                continue
            lst = out.setdefault(old, [])
            if new not in [n for n, _ in lst]:
                lst.append((new, active))
    return out


def load_sparcs(path):
    """NYS facility id -> scaler size ('1'..'10')."""
    out = {}
    with open(path, newline="", encoding="utf-8-sig") as f:
        for r in csv.DictReader(f):
            fid = (r.get("nys_facility_id") or "").strip()
            s = (r.get("scaler_size") or "").strip()
            if not fid or not s:
                continue
            if not (s.isdigit() and 1 <= int(s) <= 10):
                sys.exit(f"STOP: SPARCS lookup has a bad scaler_size '{s}' for facility {fid} (must be 1 to 10).")
            out[fid] = s
    return out


def fix(header, rows, hec, sparcs):
    """Return (header_out, rows_out, hec_log, no_scale_log, stats)."""
    base = [h for h in header if h != "SCALER_SIZE"]
    if base != EXPECTED_HEADER[:-1]:
        missing = [h for h in EXPECTED_HEADER[:-1] if h not in header]
        sys.exit("STOP: the export's columns are not the ones the roster table expects.\n"
                 f"  missing: {missing}\n  found:   {header}\n  Nothing was written.")
    ix = {h: i for i, h in enumerate(header)}
    # Build output rows in the table's column order, whatever order the input used.
    def to_table_order(row):
        return [row[ix[h]] if h in ix else "" for h in EXPECTED_HEADER]

    t_ix = {h: i for i, h in enumerate(EXPECTED_HEADER)}
    code_i, qe_i, notes_i, scale_i = t_ix["Code"], t_ix["QE Name"], t_ix["Code Notes"], t_ix["SCALER_SIZE"]
    fac_i, name_i, type_i = t_ix["NYS-Facility ID"], t_ix["Organization Name"], t_ix["Organization Type"]

    out, hec_log = [], []
    st = dict(hec_rows=0, replaced=0, extra=0, inactive=0, nomap=0, scale_set=0, scale_changed=0, scale_kept=0)
    for raw_row in rows:
        row = to_table_order(raw_row)
        variants = [row]
        if row[qe_i] == HEC_QE:
            st["hec_rows"] += 1
            old = row[code_i].strip()
            if old not in hec:
                st["nomap"] += 1
                hec_log.append(dict(facility_id=row[fac_i], organization=row[name_i], old_code=old, new_code="",
                                    new_code_active="", action="NO MAPPING - left unchanged"))
            else:
                names = hec[old]
                active_names = [n for n, a in names if a == "1"]
                use = active_names if active_names else [n for n, _ in names]
                flag = dict(names)
                variants = []
                for k, new in enumerate(use):
                    r = list(row)
                    r[code_i] = new
                    note = f"Legacy code {old} replaced by {new} (HEC lookup)"
                    if not active_names:
                        note += "; new code inactive in HEC lookup"
                    r[notes_i] = (row[notes_i] + " | " + note) if row[notes_i].strip() else note
                    variants.append(r)
                    if k == 0:
                        st["replaced"] += 1
                    else:
                        st["extra"] += 1
                    if not active_names:
                        st["inactive"] += 1
                    hec_log.append(dict(
                        facility_id=row[fac_i], organization=row[name_i], old_code=old, new_code=new,
                        new_code_active=flag[new],
                        action=("replaced" if k == 0 else "added extra row (old code has several new codes)")
                               + ("" if active_names else " - used INACTIVE lookup name")))
        for r in variants:
            fid = r[fac_i].strip()
            before = r[scale_i].strip()
            if fid in sparcs:
                r[scale_i] = sparcs[fid]
                st["scale_set"] += 1
                if before != sparcs[fid]:
                    st["scale_changed"] += 1
            elif before:
                st["scale_kept"] += 1                       # export already had a size; keep it
            out.append(r)

    # Hospitals the SPARCS lookup knows nothing about.
    seen, no_scale = set(), []
    for r in out:
        fid = r[fac_i].strip()
        if fid in seen or r[scale_i].strip() or "hospital" not in r[type_i].lower():
            continue
        seen.add(fid)
        no_scale.append(dict(facility_id=fid, organization=r[name_i], organization_type=r[type_i],
                             qe=r[qe_i], code=r[code_i]))
    return EXPECTED_HEADER, out, hec_log, no_scale, st


def write_csv(path, fieldnames, rows):
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        w.writerows(rows)


def upload(updated):
    import boto3
    s3 = boto3.Session(profile_name=PROFILE, region_name=REGION).client("s3")
    new_md5 = hashlib.md5(updated).hexdigest()
    head = s3.head_object(Bucket=BUCKET, Key=KEY)
    if head["ETag"].strip('"') == new_md5:
        print("S3 already holds exactly this file. Nothing to upload.")
        return
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup_key = f"{BACKUP_PREFIX}AA Code Report_with_SCALER_SIZE.BEFORE-{stamp}.csv"
    current = s3.get_object(Bucket=BUCKET, Key=KEY)["Body"].read()
    s3.put_object(Bucket=BUCKET, Key=backup_key, Body=current)
    print(f"Backup written:   s3://{BUCKET}/{backup_key}   ({len(current):,} bytes)")
    s3.put_object(Bucket=BUCKET, Key=KEY, Body=updated)
    h2 = s3.head_object(Bucket=BUCKET, Key=KEY)
    ok = h2["ContentLength"] == len(updated) and h2["ETag"].strip('"') == new_md5
    print(f"Replaced:         s3://{BUCKET}/{KEY}   ({h2['ContentLength']:,} bytes) -> "
          f"{'verified' if ok else 'VERIFY FAILED'}")
    if not ok:
        sys.exit("Upload could not be verified - restore from the backup above.")
    files = [o for o in s3.list_objects_v2(Bucket=BUCKET, Prefix=KEY.rsplit('/', 1)[0] + "/").get("Contents", [])
             if not o["Key"].endswith("/")]
    print(f"Files in the roster table folder: {len(files)} (must be 1)")


def newest_raw():
    found = sorted(glob.glob(str(HERE / "1-Input-Data" / "SFDC-export-RAW*.csv")), key=os.path.getmtime)
    if not found:
        sys.exit("STOP: no SFDC-export-RAW*.csv in 1-Input-Data. Save the new Salesforce export there first.")
    return found[-1]


def main():
    ap = argparse.ArgumentParser(description="Fix a raw SFDC export: HEC codes + SPARCS scale.")
    ap.add_argument("--input", help="raw SFDC export (default: newest 1-Input-Data/SFDC-export-RAW*.csv)")
    ap.add_argument("--hec-lookup", default=str(HERE / "ShowingHECOldAndNewAANames.csv"))
    ap.add_argument("--sparcs-lookup", default=str(HERE / "SPARCSScalerByFacility.csv"))
    ap.add_argument("--output", default=str(HERE / "1-Input-Data" / "AA Code Report_with_SCALER_SIZE.csv"))
    ap.add_argument("--hec-log", default=str(HERE / "3-Results" / "results-HEC-code-replacements-in-SFDC-export.csv"))
    ap.add_argument("--scale-log", default=str(HERE / "3-Results" / "results-SFDC-hospitals-without-SPARCS-scale.csv"))
    ap.add_argument("--upload", action="store_true", help="also replace the file in S3 (after a backup)")
    a = ap.parse_args()

    src = a.input or newest_raw()
    raw = read_bytes(src)
    header, rows = parse(raw)
    print(f"Input:  {src}\n        {len(rows):,} rows, {len(header)} columns")
    if serialize(header, rows) != raw and "SCALER_SIZE" in header and header[-1] == "SCALER_SIZE":
        print("NOTE: re-saving the input does not reproduce its exact bytes (line endings, quoting or a BOM "
              "differ). The output is written with CRLF line endings and minimal quoting, which Athena reads fine.")

    hec = load_hec_lookup(a.hec_lookup)
    sparcs = load_sparcs(a.sparcs_lookup)
    print(f"HEC lookup: {len(hec)} old codes | SPARCS lookup: {len(sparcs)} facilities")

    header_out, out_rows, hec_log, no_scale, st = fix(header, rows, hec, sparcs)
    updated = serialize(header_out, out_rows)

    Path(a.output).parent.mkdir(parents=True, exist_ok=True)
    with open(a.output, "wb") as f:
        f.write(updated)
    write_csv(a.hec_log, ["facility_id", "organization", "old_code", "new_code", "new_code_active", "action"], hec_log)
    write_csv(a.scale_log, ["facility_id", "organization", "organization_type", "qe", "code"], no_scale)

    print("\nFIX 1 - HEC codes")
    print(f"  HealtheConnections rows:                        {st['hec_rows']}")
    print(f"  code replaced:                                  {st['replaced']}")
    print(f"  extra rows added (old code -> several new):    {st['extra']}")
    print(f"  rows using an INACTIVE lookup name:             {st['inactive']}")
    print(f"  rows with no mapping (left as they were):       {st['nomap']}")
    print("FIX 2 - SPARCS scale")
    print(f"  rows given a SCALER_SIZE from the lookup:       {st['scale_set']:,}  (changed vs input: {st['scale_changed']:,})")
    print(f"  rows keeping a size already in the export:      {st['scale_kept']:,}")
    print(f"  hospitals with NO size in the lookup:           {len(no_scale)}  -> {a.scale_log}")
    print(f"\nRows: {len(rows):,} in -> {len(out_rows):,} out | columns: {len(header_out)}")
    print(f"Wrote {a.output} ({len(updated):,} bytes, md5 {hashlib.md5(updated).hexdigest()})")

    if a.upload:
        upload(updated)
    else:
        print("DRY RUN: nothing uploaded. Re-run with --upload to replace the file in S3.")


if __name__ == "__main__":
    main()
