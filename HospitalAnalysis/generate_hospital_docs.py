"""
Generate two Word documents explaining the chain-rank methodology, using exact
numbers from ExportoHospitalVolumenAndHIFSS.csv and the SFDC lookup CSV:
  1. MMC_Analysis.docx  -- a healthy / over-performing example
  2. WMC_Analysis.docx  -- a large chain (size 9) submitting NO data (red flag)
"""

from docx import Document
from docx.shared import Pt, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH


def add_title(doc, text):
    h = doc.add_heading(text, level=0)
    return h


def add_kv_table(doc, rows, headers=("Field", "Value")):
    table = doc.add_table(rows=1, cols=len(headers))
    table.style = "Light Grid Accent 1"
    hdr = table.rows[0].cells
    for i, htext in enumerate(headers):
        hdr[i].text = htext
        for p in hdr[i].paragraphs:
            for r in p.runs:
                r.bold = True
    for row in rows:
        cells = table.add_row().cells
        for i, val in enumerate(row):
            cells[i].text = str(val)
    return table


def add_facility_table(doc, facilities):
    headers = ("NYS Facility ID", "SHIN-NY ID", "Organization Name", "AA Code", "Scaler Size")
    table = doc.add_table(rows=1, cols=len(headers))
    table.style = "Light Grid Accent 1"
    hdr = table.rows[0].cells
    for i, htext in enumerate(headers):
        hdr[i].text = htext
        for p in hdr[i].paragraphs:
            for r in p.runs:
                r.bold = True
    for f in facilities:
        cells = table.add_row().cells
        for i, val in enumerate(f):
            cells[i].text = str(val)
    return table


def methodology_section(doc):
    doc.add_heading("How the numbers are derived (methodology)", level=1)
    steps = [
        ("Step 1 - Define the chain.",
         "A hospital \"chain\" is a single Assigning Authority (AA) code. Every SHIN-NY "
         "facility that submits to S3 under that code is rolled into one chain, because "
         "they share one EHR/EPIC feed."),
        ("Step 2 - Compute chain size.",
         "chain_size is the SUM of each facility's scaler_size (a 1-10 rank, 1 = smallest). "
         "Blank sizes count as 0. Summing reflects that a chain of several facilities is "
         "expected to produce several facilities' worth of data."),
        ("Step 3 - Rank by size.",
         "All 1,000 hospital chains are ranked by chain_size, largest first. size_rank = 1 "
         "means the single largest chain in the state."),
        ("Step 4 - Count actual submissions.",
         "Over the last 10 days (using a 3-day inventory snapshot lag, and excluding any "
         "data before the 2026-03-11 clinical-data start date), we count each chain's CCD, "
         "Lab, and TRN documents."),
        ("Step 5 - Rank by volume.",
         "Chains are ranked separately by ccd_count, lab_count, and trn_count, most first "
         "(rank 1 = top contributor)."),
        ("Step 6 - Gap = volume rank minus size rank.",
         "Each *_gap = type_rank - size_rank. A large POSITIVE gap means the chain submits "
         "far less of that type than its size implies (worry). Near zero = in line with "
         "size. Negative = submitting more than its size implies. worst_gap is the largest "
         "(most concerning) of the three gaps, and the report is sorted by it."),
    ]
    for title, body in steps:
        p = doc.add_paragraph()
        run = p.add_run(title + " ")
        run.bold = True
        p.add_run(body)


def build_mmc(path):
    doc = Document()
    add_title(doc, "PDR Submission Analysis: MMC (Montefiore / Maimonides)")

    sub = doc.add_paragraph("A healthy example - large chain, top submitter")
    sub.runs[0].italic = True

    doc.add_heading("Summary", level=1)
    doc.add_paragraph(
        "MMC is the single Assigning Authority code representing the Montefiore / "
        "Maimonides EPIC instance. It is made up of 5 hospital facilities, all submitting "
        "to S3 under the one AA code 'MMC'. With a summed size of 37 it is the 2nd-largest "
        "hospital chain in the state, yet it is the #1 submitter of CCDs, Labs, and TRNs. "
        "In other words MMC slightly OVER-performs relative to its size - exactly the "
        "pattern we want to see from a large chain."
    )

    doc.add_heading("Facilities that make up MMC", level=1)
    add_facility_table(doc, [
        ("1168", "FS000001168", "Montefiore Medical Center - Wakefield Hospital", "MMC", "8"),
        ("1169", "FS000001169", "Montefiore Medical Center - Henry & Lucy Moses Div", "MMC", "10"),
        ("1185", "FS000001185", "Montefiore Medical Center - Montefiore Westchester Square", "MMC", "(blank -> 0)"),
        ("1305", "FS000001305", "Maimonides Medical Center", "MMC", "10"),
        ("3058", "FS000003058", "Montefiore Med Center - Jack D Weiler Hosp of A Einstein College Div", "MMC", "9"),
    ])
    doc.add_paragraph(
        "Note: Maimonides (1305) is listed under QE 'Healthix' in the SFDC export while the "
        "other four are 'Bronx RHIO'. Because all five share the AA code 'MMC', they collapse "
        "into one chain, which carries a single QE label (Bronx RHIO) in the output."
    )

    doc.add_heading("MMC result row (from the export)", level=1)
    add_kv_table(doc, [
        ("QE", "Bronx RHIO"),
        ("Chain AA", "MMC"),
        ("Facility count", "5"),
        ("Chain size (summed scaler_size)", "37  (8 + 10 + 0 + 10 + 9)"),
        ("Size rank", "2  (2nd-largest chain of 1,000)"),
        ("CCD count", "1,711,735"),
        ("CCD rank", "1  (top CCD contributor)"),
        ("CCD gap", "-1"),
        ("Lab count", "371,091"),
        ("Lab rank", "1"),
        ("Lab gap", "-1"),
        ("TRN count", "223,045"),
        ("TRN rank", "1"),
        ("TRN gap", "-1"),
        ("Worst gap", "-1  (over-performing - no concern)"),
    ])

    methodology_section(doc)

    doc.add_heading("Applying it to MMC", level=1)
    doc.add_paragraph(
        "Chain size = 8 + 10 + 0 + 10 + 9 = 37, the 2nd-largest summed size of any chain "
        "(only RGHS, at 82, is larger), so size_rank = 2. MMC submitted 1,711,735 CCDs, "
        "371,091 Labs, and 223,045 TRNs - the highest volume in every type - so all three "
        "volume ranks are 1. Every gap is 1 - 2 = -1, and worst_gap = -1. A negative gap "
        "means MMC submits MORE data than its size implies: it is the #1 contributor in all "
        "three types while being only the #2 largest chain. This is the opposite of a concern."
    )

    doc.add_paragraph(
        "Data source: ExportoHospitalVolumenAndHIFSS.csv (query output) and the SFDC "
        "'AA Code Report_with_SCALER_SIZE' lookup. Figures are as current as that export."
    ).runs[0].italic = True

    doc.save(path)


def build_wmc(path):
    doc = Document()
    add_title(doc, "PDR Submission Analysis: WMC (Westchester Medical Center)")

    sub = doc.add_paragraph("A red-flag example - large chain, NO data submitted")
    sub.runs[0].italic = True

    doc.add_heading("Summary", level=1)
    doc.add_paragraph(
        "WMC (Westchester Medical Center) is a sizeable hospital with a scaler size of 9 - "
        "near the top of the 1-10 scale - yet over the last 10 days it submitted ZERO "
        "documents of every type: 0 CCDs, 0 Labs, 0 TRNs. A large facility contributing no "
        "data is a clear red flag and the kind of oddity this report is built to surface."
    )

    doc.add_heading("The WMC facility", level=1)
    doc.add_paragraph(
        "The AA code 'WMC' maps to a single facility: Westchester Medical Center "
        "(NYS Facility ID 1139, SHIN-NY ID FS000001139), size 9, under QE Hixny."
    )
    add_facility_table(doc, [
        ("1139", "FS000001139", "Westchester Medical Center", "WMC", "9"),
    ])

    doc.add_heading("WMC result row (from the export)", level=1)
    add_kv_table(doc, [
        ("QE", "Hixny"),
        ("Chain AA", "WMC"),
        ("Facility count", "1"),
        ("Chain size", "9  (a single size-9 facility)"),
        ("Size rank", "171  (of 1,000 chains)"),
        ("CCD count", "0"),
        ("CCD rank", "354  (tied last - no CCDs)"),
        ("CCD gap", "+183"),
        ("Lab count", "0"),
        ("Lab rank", "59"),
        ("Lab gap", "-112"),
        ("TRN count", "0"),
        ("TRN rank", "54"),
        ("TRN gap", "-117"),
        ("Worst gap", "+183  (CCD - the biggest concern)"),
    ])

    methodology_section(doc)

    doc.add_heading("Applying it to WMC", level=1)
    doc.add_paragraph(
        "WMC is a single size-9 facility, so chain_size = 9 and size_rank = 171 of 1,000. "
        "But it submitted 0 CCDs, 0 Labs, and 0 TRNs over the 10-day window. Because so many "
        "chains submitted zero CCDs, they tie at the bottom CCD rank of 354, giving a CCD gap "
        "of 354 - 171 = +183. That large positive gap - a reasonably big chain sitting at the "
        "very bottom of CCD submissions - is precisely the 'large chain, missing data' signal "
        "worth investigating."
    )
    doc.add_paragraph(
        "Context on the lab/TRN gaps: their gaps show as negative (-112, -117) only because "
        "huge numbers of chains ALSO submitted zero labs/TRNs, so the zero-volume rank (59 for "
        "labs, 54 for TRN) happens to sit above WMC's size rank of 171. The ranks don't change "
        "the underlying fact: WMC sent nothing. The headline remains zero data from a size-9 "
        "hospital."
    )

    doc.add_heading("Related WMCHealth facilities (different AA codes)", level=1)
    doc.add_paragraph(
        "Several other WMCHealth hospitals report under their own AA codes and were also at "
        "zero over this window:"
    )
    add_facility_table(doc, [
        ("779", "FS000000779", "Good Samaritan Hospital (WMCHealth)", "WMCBSMGGSH", "8"),
        ("180", "FS000000180", "Mid-Hudson Valley Division of Westchester Medical Center", "WMCMHRH", "6"),
        ("708", "FS000000708", "Port Jervis Community Hospital (WMCHealth)", "WMCBSCH", "3"),
        ("704", "FS000000704", "St. Anthony Community Hospital (WMCHealth)", "WMCBSSACH", "3"),
    ])

    doc.add_paragraph(
        "Data source: ExportoHospitalVolumenAndHIFSS.csv (query output) and the SFDC "
        "'AA Code Report_with_SCALER_SIZE' lookup. Figures are as current as that export."
    ).runs[0].italic = True

    doc.save(path)


if __name__ == "__main__":
    import os
    here = os.path.dirname(os.path.abspath(__file__))
    build_mmc(os.path.join(here, "MMC_Analysis.docx"))
    build_wmc(os.path.join(here, "WMC_Analysis.docx"))
    print("Wrote MMC_Analysis.docx and WMC_Analysis.docx")
