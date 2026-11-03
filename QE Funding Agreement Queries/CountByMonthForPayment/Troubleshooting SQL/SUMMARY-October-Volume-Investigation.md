# Summary: PDR volume investigation (October 2026 funding-agreement review)

**Author:** Michael Berger / PDR Analytics
**Bottom line:** What first looked like an October volume shortfall traces back to
a single systemic event: on **Friday, August 28, 2026**, platform-wide submitted
volume dropped ~50% and stayed depressed ~3.5 weeks (through ~Sep 22), then
recovered with a partial catch-up. About half of the shortfall is still not
accounted for under the expected paths. The finding reproduces across multiple
inventory snapshots.

---

## How we got here (investigation path)

1. **Started with the QE volume SLA.** Running the monthly funding-agreement
   volume report for October, several QEs appeared below their rolling baseline.

2. **Drilled in by QE.** The apparent drop was not one QE - it showed up across
   nearly all of them, which argued against a single-source explanation.

3. **Drilled in by QE by month.** Monthly totals (dated by the submission date in
   the key path) showed a step DOWN between August and September that then held
   flat - September and October were about equal. So the event was the Aug->Sep
   transition, not October getting worse.

4. **By QE, by weekday, last few days of each month.** Comparing the last three
   weekdays of October vs September per source surfaced large absolute declines,
   heavily in Healthix. (Healthix is ~half of PDR, so it dominates absolute
   numbers; the percentage pattern mattered more than the raw size.)

5. **By QE, by day, focused on early September.** The daily curve revealed the
   real shape: a clean cliff on a single day. Narrowing further pinned the onset
   to **Friday, August 28, 2026** (Aug 27 was fully normal; Aug 28 dropped ~50%
   for every QE on the same day).

6. **Characterized the event.** The ~50% drop was uniform across small, medium,
   AND large sources (~47-51% retained in every size tier) and hit ~3,580 sources
   of all sizes at once - the fingerprint of a systemic pipeline loss, not source
   behavior. It then recovered ~Sep 23 with a catch-up surge; a volume-accounting
   estimate shows only ~50% of the shortfall is accounted for so far.

## Key numbers

- Onset: **Aug 28, 2026** (same day, all QEs). Depression ~Aug 28 - Sep 22.
- Magnitude: **~50% drop**, uniform across source size tiers:
  large 50% / medium 51% / small 47% retained.
- Shortfall during depression: **~12.4M documents** below expected.
- Catch-up during recovery (Sep 23 - Oct 31): **~6.2M** (about half the shortfall).
- **~6.2M documents (~50%) are NOT yet accounted for** under the expected
  assigning-authority path in the inventory. This is NOT a claim of permanent
  loss - they may be misrouted, under a different path/date, in excluded
  (orphan/backload) sources, or pending replay. Locating them is open work.

## Multiple inventory snapshots - conclusion is stable

We did not rely on a single inventory. We re-ran the onset window against three
snapshots:

- **end of Sep (dt 2026-10-01)** and **recent (dt 2026-11-01)**: identical
  numbers for Aug 25-31, both show the Aug 27 -> Aug 28 cliff (1.59M -> 816K).
- **end of Aug (dt 2026-09-01)**: shows the SAME drop shape (Aug 28 and the
  following days depressed). Its absolute totals are lower because a snapshot
  captured right at the boundary has not yet indexed all late-August objects
  (normal inventory-completeness lag). The onset is still clearly visible.

So the Aug 28 onset and ~50% drop are not an artifact of any one inventory file.

## Exclusions / method (applied consistently)

- **Verato:** only sources matching the Verato MPI (`lookup_verato_aa`, standard
  AA normalization) are counted - orphans excluded.
- **Date / clinical-data floor:** documents before 2026-03-11 excluded
  (header-only period).
- **Backload excluded** (real-time/normal submissions only).
- **Dating:** documents are dated by the SUBMISSION date parsed from the S3 key
  path (`<type>/YYYY/Mon/DD/`), NOT `last_modified_date`. last_modified is
  re-stamped by routine S3 attribute updates and is unreliable; the key path is
  written at submission and does not change. (Parse verified on 100% of ~300M
  keys.)
- **Snapshots:** one inventory `dt` partition per run; cross-checked across the
  three partitions above.

## Queries used (GitHub)

Repo root: https://github.com/rsxmjb234/SQLForS3InventoryOfPDR

Base path: `QE Funding Agreement Queries/CountByMonthForPayment/`

- Monthly volume SLA (query of record): [Monthly-VolumneByQEByDataType.sql](https://github.com/rsxmjb234/SQLForS3InventoryOfPDR/blob/main/QE%20Funding%20Agreement%20Queries/CountByMonthForPayment/Monthly-VolumneByQEByDataType.sql)
- Per-QE CCD/TRN by submission month (the step-down): [VolumeDecline-PerQE-CCD-TRN-BySubmissionMonth.sql](https://github.com/rsxmjb234/SQLForS3InventoryOfPDR/blob/main/QE%20Funding%20Agreement%20Queries/CountByMonthForPayment/Troubleshooting%20SQL/VolumeDecline-PerQE-CCD-TRN-BySubmissionMonth.sql)
- Top-50 declining sources, last 3 weekdays Oct vs Sep: [Top50-Decline-Last3Weekdays-OctVsSep.csv](https://github.com/rsxmjb234/SQLForS3InventoryOfPDR/blob/main/QE%20Funding%20Agreement%20Queries/CountByMonthForPayment/Troubleshooting%20SQL/Top50-Decline-Last3Weekdays-OctVsSep.csv) (output)
- One source / QE by day (pinpoint onset): [Source-Detail-By-Day.sql](https://github.com/rsxmjb234/SQLForS3InventoryOfPDR/blob/main/QE%20Funding%20Agreement%20Queries/CountByMonthForPayment/Troubleshooting%20SQL/Source-Detail-By-Day.sql)
- System-wide daily totals / spike-day finder: [SystemWide-DailyTotals-FindSpikeDays.sql](https://github.com/rsxmjb234/SQLForS3InventoryOfPDR/blob/main/QE%20Funding%20Agreement%20Queries/CountByMonthForPayment/Troubleshooting%20SQL/SystemWide-DailyTotals-FindSpikeDays.sql)

## Related documents

- Investigation ticket (onset, scope, size-tier evidence, volume accounting):
  [TICKET-2-Onset-Aug28-SystemicHalfVolumeLoss.md](https://github.com/rsxmjb234/SQLForS3InventoryOfPDR/blob/main/QE%20Funding%20Agreement%20Queries/CountByMonthForPayment/Troubleshooting%20SQL/TICKET-2-Onset-Aug28-SystemicHalfVolumeLoss.md)
- Earlier broad-decline write-up: [ISSUE-PDR-Volume-Decline-Sept2026.md](https://github.com/rsxmjb234/SQLForS3InventoryOfPDR/blob/main/QE%20Funding%20Agreement%20Queries/CountByMonthForPayment/Troubleshooting%20SQL/ISSUE-PDR-Volume-Decline-Sept2026.md)
- Monthly QE volume memo (CCD only this month; Sept excluded from baseline):
  `10-2026 Oct Review of Data Volume Gaps in Data for PDR.txt`
