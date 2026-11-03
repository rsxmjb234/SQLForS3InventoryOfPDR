# [PDR] Broad CCD & TRN volume decline starting September 2026

**Type:** Data Quality / Investigation
**Component:** PDR ingestion / submission volume
**Reporter:** NYeC PDR Analytics
**Affects:** All QEs, CCD and TRN
**Environment:** `pdr_inventory.pdr_inventory_prod_data_all` (prod inventory), account 220065406231

---

## Summary

Submitted CCD and TRN volume dropped sharply and broadly starting in
**September 2026** and stayed down through October. Nearly every QE is affected,
in both data types, at the same time (30-50% declines), which points to a
**systemic change around the Aug -> Sep boundary** rather than one source.

## How volume is measured (important)

- **Documents are dated by their SUBMISSION date, parsed from the S3 KEY PATH**
  (`<type>/YYYY/Mon/DD/`), e.g. `MMC/trn/2026/Aug/15/12/...`. This is the date
  the file was submitted and is written into the key at that time.
- We deliberately do **NOT** use `last_modified_date`. PDR updates S3 object
  attributes/metadata independently of submission (and does so routinely), which
  re-stamps `last_modified_date` and makes it unreliable as a submission date.
  The key path never changes after write, so it is the trustworthy measure.
- **Backload excluded** (real-time/normal submissions only).
- **Orphans excluded** (only sources matching the Verato MPI, standard AA
  normalization) - so this is not an artifact of old/non-participant sources.
- **Header-only period excluded** (nothing before 2026-03-11, when only document
  headers were written).

## System-wide monthly volume (Verato-matched, by submission date)

| Month | CCD | CCD / day | TRN |
|-------|-----|-----------|-----|
| 2026-06 | 21,213,509 | 707,117 | 17,944,957 |
| 2026-07 | 21,751,559 | 701,663 | 15,301,454 |
| 2026-08 | 24,816,349 | 800,527 | 15,666,924 |
| 2026-09 | 18,712,741 | 623,758 |  9,768,874 |
| 2026-10 | 18,648,072 | 601,551 | 10,249,572 |

- Normalized per day (each month has its full 30/31 days; October is complete in
  this snapshot), so this is **not** a month-length or incomplete-month effect.
- CCD/day stepped down from ~700-800K (Jun-Aug) to ~600-620K (Sep-Oct).
- TRN fell harder: ~15-18M (Jun-Aug) down to ~10M (Sep-Oct), roughly a 35% drop.

## Per-QE breakdown (the decline is broad, not one source)

Counts by submission month; "Sep vs Aug" is the month-over-month change into the
decline.

| QE | Type | Jun | Jul | Aug | Sep | Oct | Sep vs Aug |
|----|------|-----|-----|-----|-----|-----|------------|
| bronx | CCD | 997,303 | 1,482,050 | 1,336,128 | 637,475 | 792,759 | **-52%** |
| bronx | TRN | 1,669,112 | 2,113,172 | 1,942,929 | 1,066,194 | 1,285,459 | **-45%** |
| healtheconnections | CCD | 6,679,175 | 5,587,624 | 6,730,826 | 4,289,513 | 4,433,441 | **-36%** |
| healtheconnections | TRN | 5,058,836 | 4,079,280 | 4,843,062 | 3,187,257 | 3,200,694 | **-34%** |
| healthix | CCD | 6,858,393 | 7,405,588 | 9,596,829 | 6,638,766 | 7,644,669 | **-31%** |
| healthix | TRN | 7,184,506 | 6,129,151 | 6,005,714 | 3,854,898 | 4,067,320 | **-36%** |
| hixny | CCD | 3,555,414 | 3,826,515 | 3,818,894 | 4,905,283 | 3,267,044 | +28% |
| hixny | TRN | 282,719 | 331,542 | 302,029 | 210,570 | 135,300 | **-30%** |
| rochester | CCD | 1,679,066 | 1,823,695 | 1,755,561 | 1,260,838 | 1,400,730 | **-28%** |
| rochester | TRN | 788,628 | 811,227 | 716,282 | 560,440 | 570,668 | **-22%** |
| techbd | CCD | 1,444,158 | 1,626,087 | 1,578,111 | 980,866 | 1,109,429 | **-38%** |
| techbd | TRN | 2,961,156 | 1,837,082 | 1,856,908 | 889,515 | 990,131 | **-52%** |

Observations:
- **11 of 12 QE/data-type series dropped in September** (30-52%). The breadth and
  simultaneity across independent QEs and both data types is the main signal that
  this is systemic, not per-source.
- The single exception is **hixny CCD (+28%)**, so the September change is not a
  uniform mechanical clipping of all data - it still varies by QE.
- The decline holds in October (does not recover).

## What this means for the volume SLA

Because this is a broad, real decline (measured on true submission dates, orphans
and backload excluded), the funding-agreement rolling-baseline SLA will flag
multiple QEs as >10% below baseline for October. That is a correct reflection of
the data: submitted volume genuinely fell starting September. Whether the cause is
"attributable to expected changes" (per the agreement) is the open question to run
down.

## Query

Exact SQL (dated by key-path submission date, Verato-matched, backload &
header-only excluded):

- [VolumeDecline-PerQE-CCD-TRN-BySubmissionMonth.sql](https://github.com/rsxmjb234/SQLForS3InventoryOfPDR/blob/main/QE%20Funding%20Agreement%20Queries/CountByMonthForPayment/Troubleshooting%20SQL/VolumeDecline-PerQE-CCD-TRN-BySubmissionMonth.sql)

Repo root: https://github.com/rsxmjb234/SQLForS3InventoryOfPDR

Scope note: this covers CCD and TRN. Labs (`lab` path segment) are not included
here and can be assessed separately.
