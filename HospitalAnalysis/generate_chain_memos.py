"""
Generate one Word memo per hospital chain from the latest export
(ReportOnActualPDRVolumneForEveryHospital*.csv).

Output folder : MemoPerHospital/
File naming    : {cohort}-{QE}-{Clean|Issues}-{chain_aa}.docx
                 cohort 1..5 = size quintile (1 = top 20% largest).

Clean vs Issues rule (a chain is "Issues" when):
    any of ccd/lab/trn count == 0  OR  worst_gap >= GAP_THRESHOLD
We focus on the largest systems, but surface an issue for any size so the QE
is aware.
"""

import csv
import os
import re
from datetime import date, timedelta

GAP_THRESHOLD = 50      # worst_gap at/above which volume badly trails size
TOTAL_CHAINS = 0        # set in main() from the actual export row count

# Data-window parameters (must match ChainRankSizeVsVolume.sql config).
LOOKBACK_DAYS = 10
INVENTORY_LAG_DAYS = 3

HERE = os.path.dirname(os.path.abspath(__file__))


def _data_window():
    """Return (start_date, end_date) matching the SQL config, relative to today."""
    today = date.today()
    end = today - timedelta(days=INVENTORY_LAG_DAYS)
    start = today - timedelta(days=(LOOKBACK_DAYS + INVENTORY_LAG_DAYS - 1))
    return start, end


def _fmt(d):
    # Non-padded day: %#d on Windows, %-d elsewhere.
    fmt = "%B %#d, %Y" if os.name == "nt" else "%B %-d, %Y"
    return d.strftime(fmt)


def _window_phrase():
    start, end = _data_window()
    return f"{_fmt(start)} to {_fmt(end)}"


def _find_export():
    import glob
    matches = sorted(glob.glob(os.path.join(HERE, "ReportOnActualPDRVolumneForEveryHospital*.csv")))
    if not matches:
        raise FileNotFoundError("No ReportOnActualPDRVolumneForEveryHospital*.csv found in " + HERE)
    # Prefer the shortest name (the clean single-.csv export) if several exist.
    return min(matches, key=len)


EXPORT = _find_export()
OUT_DIR = os.path.join(HERE, "MemoPerHospital")


def to_int(v):
    try:
        return int(str(v).strip())
    except (ValueError, TypeError):
        return 0


def ordinal(n):
    n = int(n)
    if 10 <= (n % 100) <= 20:
        suffix = "th"
    else:
        suffix = {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
    return f"{n}{suffix}"


def sanitize(name):
    # Remove characters illegal in Windows filenames and collapse whitespace.
    name = re.sub(r'[\\/:*?"<>|]', "", str(name))
    name = re.sub(r"\s+", " ", name).strip()
    return name.replace(" ", "")


def cohort_of(size_rank, total):
    """1..5 quintile by size_rank (1 = top 20% largest)."""
    if total <= 0:
        return 5
    c = int((to_int(size_rank) - 1) * 5 / total) + 1
    return max(1, min(5, c))


def classify(row):
    ccd = to_int(row["ccd_count"])
    lab = to_int(row["lab_count"])
    trn = to_int(row["trn_count"])
    worst = to_int(row["worst_gap"])
    missing_any = (ccd == 0) or (lab == 0) or (trn == 0)
    big_gap = worst >= GAP_THRESHOLD
    if missing_any or big_gap:
        return "Issues"
    return "Clean"


def add_context(doc, status):
    doc.add_heading("Context", level=1)
    doc.add_paragraph(
        "This memo reviews the clinical data a hospital chain is contributing to the "
        "Primary Document Repository (PDR). Each chain is matched to the latest hospital "
        "roster exported from NYeC's Salesforce, which tells us who the facility is, "
        "which Assigning Authority (AA) code it submits under, and a size rating."
    )
    doc.add_paragraph(
        "Our attention is focused first on the largest systems, where a gap has the biggest "
        "impact on the data available in the PDR. That said, we want each QE to be aware of "
        "any issue with its sources regardless of size, so this review covers every hospital "
        "chain. A system that is missing a data type, or that sits lower in submission volume "
        "than its size would suggest, is worth a look."
    )
    if status == "Issues":
        doc.add_paragraph(
            "This chain is flagged for follow-up: it is missing one or more data types, or "
            "is submitting well below what its size would suggest."
        ).runs[0].bold = True
    else:
        doc.add_paragraph(
            "This chain currently looks healthy: its submission volume is in line with (or "
            "ahead of) what its size would suggest, with no missing data types."
        ).runs[0].bold = True


def add_interpretation(doc, row, status):
    doc.add_heading("Interpretation", level=1)
    size = to_int(row["chain_size"])
    rank = to_int(row["size_rank"])
    rank_phrase = f"the {ordinal(rank)} largest hospital chain according to SPARCS"
    ccd = to_int(row["ccd_count"])
    lab = to_int(row["lab_count"])
    trn = to_int(row["trn_count"])
    worst = to_int(row["worst_gap"])
    missing = [t for t, v in (("CCD", ccd), ("Lab", lab), ("TRN", trn)) if v == 0]

    if status == "Issues":
        parts = [f"This chain is {rank_phrase} (of {TOTAL_CHAINS}, by summed size {size})."]
        if missing:
            if len(missing) > 1:
                missing_str = ", ".join(missing[:-1]) + " and " + missing[-1]
            else:
                missing_str = missing[0]
            parts.append(
                f"Between {_window_phrase()} it submitted zero {missing_str} documents, "
                f"a clear missing-data gap."
            )
        if worst >= GAP_THRESHOLD:
            parts.append(
                f"Its submission volume ranks well below where its size would place it "
                f"(worst rank gap +{worst})."
            )
        doc.add_paragraph(" ".join(parts))
    else:
        if worst < 0:
            doc.add_paragraph(
                f"This chain is {rank_phrase} (of {TOTAL_CHAINS}, by summed size {size}). "
                f"Between {_window_phrase()} it submitted more data than its size would "
                f"suggest, a healthy pattern."
            )
        else:
            doc.add_paragraph(
                f"This chain is {rank_phrase} (of {TOTAL_CHAINS}, by summed size {size}). "
                f"Between {_window_phrase()} its submissions were in line with its size, "
                f"with no missing data types."
            )


def add_call_to_action(doc, row, status):
    if status != "Issues":
        return
    doc.add_heading("Call to action", level=1)
    doc.add_paragraph("One of the following is likely needed:")
    doc.add_paragraph(
        "Update Salesforce with the proper Assigning Authority for this source "
        "(if the roster no longer matches how the source submits), or",
        style="List Number",
    )
    doc.add_paragraph(
        "Follow up with Lisa on why this source is not submitting data commensurate "
        "with its size.",
        style="List Number",
    )


def add_facilities(doc, row):
    doc.add_heading("Facilities in this chain", level=1)
    names = [n.strip() for n in str(row["hospital_name"]).split(";") if n.strip()]
    if not names:
        doc.add_paragraph("(No facility names available in the export.)")
        return
    for n in names:
        doc.add_paragraph(n, style="List Bullet")


def add_result_table(doc, row):
    doc.add_heading("Result row (from the latest export)", level=1)
    pairs = [
        ("QE", row["qe"]),
        ("Chain AA code", row["chain_aa"]),
        ("Facility count", row["facility_count"]),
        ("Chain size (summed)", row["chain_size"]),
        ("Size rank (1 = largest)", row["size_rank"]),
        ("CCD count", f'{to_int(row["ccd_count"]):,}'),
        ("Lab count", f'{to_int(row["lab_count"]):,}'),
        ("TRN count", f'{to_int(row["trn_count"]):,}'),
    ]
    table = doc.add_table(rows=1, cols=2)
    table.style = "Light Grid Accent 1"
    h = table.rows[0].cells
    h[0].text, h[1].text = "Field", "Value"
    for c in h:
        for p in c.paragraphs:
            for r in p.runs:
                r.bold = True
    for k, v in pairs:
        cells = table.add_row().cells
        cells[0].text = str(k)
        cells[1].text = str(v)


def add_methodology(doc):
    doc.add_heading("How the numbers are derived (methodology)", level=1)
    steps = [
        ("Step 1 - Define the chain.",
         "A hospital \"chain\" is a single AA code per the NYeC Salesforce system. Every "
         "facility that submits under that code is rolled into one chain, because they share "
         "one feed."),
        ("Step 2 - Compute chain size.",
         "chain_size is the sum of each facility's size rating (1-10, 1 = smallest; blanks "
         "count as 0). Summing reflects that a multi-facility chain should produce several "
         "facilities' worth of data."),
        ("Step 3 - Rank by size.",
         f"All {TOTAL_CHAINS} active hospital chains are ranked by chain_size, largest first "
         f"(size rank 1 = largest chain in the state)."),
        ("Step 4 - Count actual submissions.",
         f"Looking at data from {_window_phrase()} (using a 3-day inventory snapshot lag, and "
         f"excluding data before the 2026-03-11 clinical-data start date), we count each "
         f"chain's CCD, Lab, and TRN documents."),
        ("Step 5 - Rank by volume.",
         "Chains are ranked separately by CCD, Lab, and TRN volume, most first (rank 1 = top "
         "contributor)."),
        ("Step 6 - Gap = volume rank minus size rank.",
         "Each gap = type rank - size rank. A large positive gap means the chain submits far "
         "less of that type than its size would suggest. worst_gap is the largest of the "
         "three gaps and, together with any missing data type, drives the Clean/Issues flag."),
    ]
    for title, body in steps:
        p = doc.add_paragraph()
        p.add_run(title + " ").bold = True
        p.add_run(body)


def build_doc(row, out_path):
    from docx import Document
    status = classify(row)
    doc = Document()
    doc.add_heading(
        f'PDR Submission Memo: {row["chain_aa"]} ({row["qe"]})', level=0
    )
    label = doc.add_paragraph(f'Status: {status}')
    label.runs[0].bold = True
    add_context(doc, status)
    add_interpretation(doc, row, status)
    add_call_to_action(doc, row, status)
    add_facilities(doc, row)
    add_result_table(doc, row)
    add_methodology(doc)
    doc.add_paragraph(
        "Data source: ReportOnActualPDRVolumneForEveryHospital export (query output) and "
        "the latest NYeC Salesforce hospital roster. Figures are as current as that export."
    ).runs[0].italic = True
    doc.save(out_path)
    return status


def main():
    global TOTAL_CHAINS
    os.makedirs(OUT_DIR, exist_ok=True)
    counts = {"Clean": 0, "Issues": 0}
    used = {}
    with open(EXPORT, newline="", encoding="utf-8-sig") as fh:
        rows = list(csv.DictReader(fh))
    TOTAL_CHAINS = len(rows)
    for row in rows:
        status = classify(row)
        cohort = cohort_of(row["size_rank"], TOTAL_CHAINS)
        qe = sanitize(row["qe"]) or "UnknownQE"
        code = sanitize(row["chain_aa"]) or "UnknownAA"
        base = f"{cohort}-{qe}-{status}-{code}"
        n = used.get(base, 0)
        used[base] = n + 1
        fname = base + (f"_{n+1}" if n else "") + ".docx"
        build_doc(row, os.path.join(OUT_DIR, fname))
        counts[status] += 1
    print(f'Wrote {counts["Clean"] + counts["Issues"]} memos to {OUT_DIR}')
    print(f'  Clean : {counts["Clean"]}')
    print(f'  Issues: {counts["Issues"]}')
    print(f'  Data window: {_window_phrase()}')


if __name__ == "__main__":
    main()
