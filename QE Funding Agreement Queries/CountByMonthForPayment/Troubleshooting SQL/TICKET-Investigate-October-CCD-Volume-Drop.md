# [INVESTIGATE] Why did CCD volume drop in October 2026 across all QEs?

**Type:** Investigation
**Priority:** High
**Reporter:** Michael Berger
**Assignee:** PDR Analytics team
**Environment:** Athena `pdr_inventory.pdr_inventory_prod_data_all` (prod inventory), AWS account 220065406231, workgroup `primary`, results to `s3://pdr-nyec-local/MichaelAthenaResults/`

---

## Ask

Determine the ROOT CAUSE of a broad CCD submission-volume decline that begins in
September 2026 and persists in October. We have confirmed the drop is real and
ruled out several explanations (below). We need to know WHY it is happening so we
can state whether it is "attributable to expected changes" under the funding
agreement or is a genuine compliance problem.

## The finding (confirmed)

CCD volume in October is 10-44% below the clean July/August baseline, for every
QE. September is excluded from the baseline due to a known PDR bulk re-stamp
anomaly (see "Ruled out" #2).

October CCD vs July/August average (Verato-matched, backload excluded, dated by
submission date from the key path):

| QE | Oct CCD | Jul/Aug avg | Oct % of baseline |
|----|---------|-------------|-------------------|
| bronx | 792,759 | 1,409,089 | 56% |
| techbd | 1,109,429 | 1,602,099 | 69% |
| healtheconnections | 4,433,441 | 6,159,225 | 72% |
| rochester | 1,400,730 | 1,789,628 | 78% |
| hixny | 3,267,044 | 3,822,704 | 85% |
| healthix | 7,644,669 | 8,501,208 | 90% |

System-wide monthly CCD (per-day normalized):

| Month | CCD | CCD/day |
|-------|-----|---------|
| Jun | 21,213,509 | 707,117 |
| Jul | 21,751,559 | 701,663 |
| Aug | 24,816,349 | 800,527 |
| Sep | 18,712,741 | 623,758 |
| Oct | 18,648,072 | 601,551 |

TRN shows an even larger drop over the same period (~15-18M/mo Jun-Aug down to
~10M/mo Sep-Oct), so whatever this is likely affects more than CCD.

## Theories ALREADY EXPLORED - do not re-test these

1. **Incomplete / too-early-in-November month.** RULED OUT. We pulled the
   system-wide daily totals by submission date through Oct 31; October is a full,
   complete month in the snapshot with no tail-off in the final days. Waiting does
   not change it.

2. **September bulk re-stamp inflating the baseline.** IDENTIFIED and handled.
   `last_modified_date` was re-stamped en masse on 2026-09-14, -15, and -22
   (millions of OLD docs moved to those days), which is why we now date by the KEY
   PATH submission date, not `last_modified_date`, and why September is excluded
   from the baseline. This is a measurement fix, not the cause of the October drop
   (the drop persists on true submission dates).

3. **Backload counted as real-time.** RULED OUT. All queries exclude
   `backload/`. Backload is also essentially done, so it is not masking volume.

4. **Orphan / non-participant sources skewing counts.** RULED OUT. All volume
   queries INNER JOIN to the Verato MPI (`lookup_verato_aa`) with standard AA
   normalization; only matched sources are counted. Excluding orphans barely moved
   the numbers, so the drop is in legitimate, matched sources.

5. **Header-only early data.** RULED OUT. All queries exclude anything before
   2026-03-11 (the header-only period).

6. **Duplicate objects inflating earlier months.** INVESTIGATED and DISPROVEN.
   We suspected CCDs were stored 3-4x (a 64-hex key segment looked like a content
   hash). It is NOT a content hash: objects sharing that value have 9,092 distinct
   file sizes (46 B to 3.6 MB), so they are different documents. Full S3 keys are
   essentially unique (157,758,494 objects vs 157,758,465 distinct keys). There
   are no stub/empty CCDs (0 under 1 KB). `e_tag` (true MD5) is empty in the
   inventory, so we have no content fingerprint. CONCLUSION: no evidence of
   duplication; this is not the cause.

7. **Fewer weekdays in October (calendar effect).** RULED OUT. Healthcare volume
   is weekday-driven, so we normalized to CCDs-per-weekday (Mon-Fri only). The
   decline persists nearly unchanged (e.g. bronx 58%, healtheconnections 72%,
   techbd 68% of the Jul/Aug per-weekday baseline). Weekday counts were nearly
   equal anyway (Jul 23, Aug 21, Oct 22).

## Theories NOT yet explored (candidate next steps)

- **Source/feed change at the Aug->Sep boundary.** The drop is broad (all QEs,
  CCD + TRN, same month), which points to something systemic on the PDR side
  (ingestion, routing, connector change, dedupe/filter added, retention or
  lifecycle change) rather than many sources independently dropping. Correlate
  against PDR deploy/change logs around 2026-08-31 / 2026-09-01.
- **Key-path date semantics.** We now date by the key path `<type>/YYYY/Mon/DD/`.
  Confirm this path date is the SUBMISSION date and that the path convention did
  not change around September (which could make recent months look lighter). Note
  hixny CCD actually ROSE (+28% Sep vs Aug), which argues against a uniform
  dating artifact, but it is worth confirming.
- **Per-source drill-down.** For the worst QEs (bronx, techbd), identify which
  assigning authorities drove the drop (did specific large sources fall off?).
  Methodology already exists - see the drill-down / by-day queries referenced
  below.
- **Is the drop in NEW documents or in how many copies/representations are
  written?** Tie-in to the e_tag gap: if we can populate a real content
  fingerprint, confirm whether "volume" semantics changed.

## Queries run (GitHub) - all in the shared repo

Repo root: https://github.com/rsxmjb234/SQLForS3InventoryOfPDR

- Monthly volume SLA (query of record): [Monthly-VolumneByQEByDataType.sql](https://github.com/rsxmjb234/SQLForS3InventoryOfPDR/blob/main/QE%20Funding%20Agreement%20Queries/CountByMonthForPayment/Monthly-VolumneByQEByDataType.sql)
- Per-QE CCD/TRN decline by submission month: [VolumeDecline-PerQE-CCD-TRN-BySubmissionMonth.sql](https://github.com/rsxmjb234/SQLForS3InventoryOfPDR/blob/main/QE%20Funding%20Agreement%20Queries/CountByMonthForPayment/Troubleshooting%20SQL/VolumeDecline-PerQE-CCD-TRN-BySubmissionMonth.sql)
- System-wide daily totals / spike-day finder (detects re-stamp artifacts; uses last_modified intentionally): [SystemWide-DailyTotals-FindSpikeDays.sql](https://github.com/rsxmjb234/SQLForS3InventoryOfPDR/blob/main/QE%20Funding%20Agreement%20Queries/CountByMonthForPayment/Troubleshooting%20SQL/SystemWide-DailyTotals-FindSpikeDays.sql)
- One source by day (pinpoints when a source changed): [Source-Detail-By-Day.sql](https://github.com/rsxmjb234/SQLForS3InventoryOfPDR/blob/main/QE%20Funding%20Agreement%20Queries/CountByMonthForPayment/Troubleshooting%20SQL/Source-Detail-By-Day.sql)
- One source over time (monthly): [Source-Detail-Over-Time.sql](https://github.com/rsxmjb234/SQLForS3InventoryOfPDR/blob/main/QE%20Funding%20Agreement%20Queries/CountByMonthForPayment/Troubleshooting%20SQL/Source-Detail-Over-Time.sql)
- Per-source month A vs month B drill-down (who drove a drop): [Bronx-CCD-SourceDrilldown-Aug-vs-Oct.sql](https://github.com/rsxmjb234/SQLForS3InventoryOfPDR/blob/main/QE%20Funding%20Agreement%20Queries/CountByMonthForPayment/Troubleshooting%20SQL/Bronx-CCD-SourceDrilldown-Aug-vs-Oct.sql)
- Day-anomaly "who spiked" explorer: [Day-Anomaly-Explore-WhoSpiked.sql](https://github.com/rsxmjb234/SQLForS3InventoryOfPDR/blob/main/QE%20Funding%20Agreement%20Queries/CountByMonthForPayment/Troubleshooting%20SQL/Day-Anomaly-Explore-WhoSpiked.sql)
- Related memo (broad decline write-up): [ISSUE-PDR-Volume-Decline-Sept2026.md](https://github.com/rsxmjb234/SQLForS3InventoryOfPDR/blob/main/QE%20Funding%20Agreement%20Queries/CountByMonthForPayment/Troubleshooting%20SQL/ISSUE-PDR-Volume-Decline-Sept2026.md)

## Standing conventions (see rules.md)

- Date documents by the key-path submission date (`<type>/YYYY/Mon/DD/`), NOT
  `last_modified_date` (which is re-stamped by routine S3 attribute updates).
- Exclude backload, exclude orphans (Verato inner join), exclude pre-2026-03-11.
- Read one recent complete inventory `dt` snapshot; scan reducer on
  `last_modified_date >= 2026-03-11` does not affect results.
