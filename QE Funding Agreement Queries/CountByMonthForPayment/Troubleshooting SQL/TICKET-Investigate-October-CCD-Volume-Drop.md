# [INVESTIGATE] One-time CCD/TRN volume step-down at the Aug->Sep 2026 boundary

**Type:** Investigation
**Priority:** High
**Reporter:** Michael Berger
**Assignee:** PDR Analytics team
**Environment:** Athena `pdr_inventory.pdr_inventory_prod_data_all` (prod inventory), AWS account 220065406231, workgroup `primary`, results to `s3://pdr-nyec-local/MichaelAthenaResults/`

---

## Ask

Determine the ROOT CAUSE of a broad, one-time CCD (and TRN) volume **step-down**
that occurred at the **August -> September 2026 boundary** and then held flat.
This is NOT an "October got worse" problem - October is essentially equal to
September. The question is: what changed around 2026-08-31 / 2026-09-01 that moved
the whole platform to a new, lower steady-state?

## Key reframing (this corrects the earlier "October drop" framing)

System-wide CCD volume by submission month (Verato-matched, backload excluded,
dated by key-path submission date):

| Month | CCD | CCD/day |
|-------|-----|---------|
| Jun | 21,213,509 | 707,117 |
| Jul | 21,751,559 | 701,663 |
| Aug | 24,816,349 | 800,527 |
| **Sep** | **18,712,741** | **623,758** |
| **Oct** | **18,648,072** | **601,551** |

- The drop is a **single step down between August and September** (~22% on CCD/day).
- **September and October are nearly identical** (18.71M vs 18.65M; 624K vs 602K
  per day). October did not decline further - it held at the new September level.
- So the event to investigate is the Aug->Sep transition, not anything in October.
- TRN shows the same step-down, larger (~15-18M/mo Jun-Aug down to ~10M/mo
  Sep-Oct), so this is not CCD-specific.

## Funding-agreement SLA under different baselines (CCD, 10%-below rule)

**Oct vs September baseline (consecutive month):** only ONE QE fails.

| QE | Sep (baseline) | Oct | Oct % of Sep | SLA |
|----|----------------|-----|--------------|-----|
| bronx | 637,475 | 792,759 | 124% | PASS |
| healtheconnections | 4,289,513 | 4,433,441 | 103% | PASS |
| healthix | 6,638,766 | 7,644,669 | 115% | PASS |
| hixny | 4,905,283 | 3,267,044 | 67% | **FAIL** |
| rochester | 1,260,838 | 1,400,730 | 111% | PASS |
| techbd | 980,866 | 1,109,429 | 113% | PASS |

- 5 of 6 QEs are stable-to-UP from September to October (103-124%).
- The only failure, **hixny (67%)**, is a baseline artifact: hixny's September was
  anomalously HIGH (Sep 4.9M vs its ~3.8M Jun-Aug norm), so October (3.27M, near its
  historical level) only looks low relative to that inflated September. Against a
  Jul/Aug baseline hixny Oct is ~85%. So hixny is not a genuine October shortfall.

**Oct vs July/August baseline (pre-step-down):** ALL six QEs fail (56-90% of
baseline), because that baseline predates the Aug->Sep step-down. This is the
"true decline" view and is why the step-down matters.

Takeaway: the SLA result depends entirely on whether the baseline is before or
after the Aug->Sep step-down. That is exactly why we need the root cause - to know
whether the step-down is "attributable to expected changes" under the agreement.

## Theories ALREADY EXPLORED - do not re-test these

1. **Incomplete / too-early-in-November month.** RULED OUT. System-wide daily
   totals by submission date run through Oct 31; October is complete with no
   tail-off in the final days. Also moot now - the event is Aug->Sep, not October.

2. **last_modified re-stamp (2026-09-14/-15/-22 bulk events).** IDENTIFIED and
   handled. `last_modified_date` was mass re-stamped on those days (millions of
   OLD docs). We therefore date by the KEY-PATH submission date, not
   `last_modified_date`. The step-down persists on true submission dates, so the
   re-stamp is a measurement issue, not the cause of the step-down.

3. **Backload counted as real-time.** RULED OUT. All queries exclude `backload/`;
   backload is essentially complete.

4. **Orphan / non-participant sources.** RULED OUT. All volume queries INNER JOIN
   to the Verato MPI (`lookup_verato_aa`) with standard AA normalization; excluding
   orphans barely moved the numbers.

5. **Header-only early data.** RULED OUT. All queries exclude pre-2026-03-11.

6. **Duplicate objects inflating earlier months.** INVESTIGATED and DISPROVEN.
   The 64-hex key segment is NOT a content hash (objects sharing it have 9,092
   distinct sizes, 46 B - 3.6 MB). Full keys are essentially unique (157,758,494
   objects vs 157,758,465 distinct keys). No stub CCDs (0 under 1 KB). `e_tag`
   (true MD5) is empty in the inventory. No evidence of duplication.

7. **Fewer weekdays in October (calendar effect).** RULED OUT. Normalized to
   CCDs-per-weekday (Mon-Fri); the Aug->Sep step-down persists nearly unchanged.
   Weekday counts were nearly equal (Jul 23, Aug 21, Oct 22).

## Theories NOT yet explored (candidate next steps)

- **PDR-side change on/around 2026-08-31 / 2026-09-01.** The step-down is broad
  (all QEs, CCD + TRN, same boundary) and one-time, which strongly suggests a
  systemic change: an ingestion/connector/routing change, a new filter or dedupe,
  a retention/lifecycle change, or a path/convention change. Correlate against PDR
  deploy/change logs and infra changes at that boundary.
- **Key-path date/convention change in September.** We date by the key path
  `<type>/YYYY/Mon/DD/`. Confirm the path convention did not change at the Aug->Sep
  boundary in a way that reassigns or drops documents. Counter-evidence: hixny CCD
  actually ROSE in September, which argues against a uniform mechanical artifact.
- **Per-source drill-down at the boundary.** For the biggest contributors, use the
  Aug-vs-Sep drill-down to see whether the step-down is concentrated in specific
  assigning authorities or uniform across them (uniform => PDR-side; concentrated
  => source/feed side).
- **e_tag / content fingerprint gap.** `e_tag` is empty; if it can be populated,
  confirm whether "volume" semantics (new documents vs representations written)
  changed at the boundary.

## Queries run (GitHub) - shared repo

Repo root: https://github.com/rsxmjb234/SQLForS3InventoryOfPDR

- Monthly volume SLA (query of record): [Monthly-VolumneByQEByDataType.sql](https://github.com/rsxmjb234/SQLForS3InventoryOfPDR/blob/main/QE%20Funding%20Agreement%20Queries/CountByMonthForPayment/Monthly-VolumneByQEByDataType.sql)
- Per-QE CCD/TRN by submission month (the step-down table): [VolumeDecline-PerQE-CCD-TRN-BySubmissionMonth.sql](https://github.com/rsxmjb234/SQLForS3InventoryOfPDR/blob/main/QE%20Funding%20Agreement%20Queries/CountByMonthForPayment/Troubleshooting%20SQL/VolumeDecline-PerQE-CCD-TRN-BySubmissionMonth.sql)
- System-wide daily totals / spike-day finder (uses last_modified intentionally): [SystemWide-DailyTotals-FindSpikeDays.sql](https://github.com/rsxmjb234/SQLForS3InventoryOfPDR/blob/main/QE%20Funding%20Agreement%20Queries/CountByMonthForPayment/Troubleshooting%20SQL/SystemWide-DailyTotals-FindSpikeDays.sql)
- One source by day: [Source-Detail-By-Day.sql](https://github.com/rsxmjb234/SQLForS3InventoryOfPDR/blob/main/QE%20Funding%20Agreement%20Queries/CountByMonthForPayment/Troubleshooting%20SQL/Source-Detail-By-Day.sql)
- One source over time (monthly): [Source-Detail-Over-Time.sql](https://github.com/rsxmjb234/SQLForS3InventoryOfPDR/blob/main/QE%20Funding%20Agreement%20Queries/CountByMonthForPayment/Troubleshooting%20SQL/Source-Detail-Over-Time.sql)
- Per-source month A vs month B drill-down (adapt to Aug vs Sep): [Bronx-CCD-SourceDrilldown-Aug-vs-Oct.sql](https://github.com/rsxmjb234/SQLForS3InventoryOfPDR/blob/main/QE%20Funding%20Agreement%20Queries/CountByMonthForPayment/Troubleshooting%20SQL/Bronx-CCD-SourceDrilldown-Aug-vs-Oct.sql)
- Day-anomaly "who spiked" explorer: [Day-Anomaly-Explore-WhoSpiked.sql](https://github.com/rsxmjb234/SQLForS3InventoryOfPDR/blob/main/QE%20Funding%20Agreement%20Queries/CountByMonthForPayment/Troubleshooting%20SQL/Day-Anomaly-Explore-WhoSpiked.sql)

## Standing conventions (see rules.md)

- Date documents by the key-path submission date (`<type>/YYYY/Mon/DD/`), NOT
  `last_modified_date` (re-stamped by routine S3 attribute updates).
- Exclude backload, exclude orphans (Verato inner join), exclude pre-2026-03-11.
- Read one recent complete inventory `dt` snapshot; the
  `last_modified_date >= 2026-03-11` filter is a scan reducer only and does not
  affect results.
