# [INVESTIGATE] Systemic ~50% volume loss starting Friday Aug 28, 2026 (recovered ~Sep 22)

**Type:** Investigation / Incident root-cause
**Priority:** High
**Reporter:** Michael Berger
**Assignee:** PDR engineering
**Environment:** Athena `pdr_inventory.pdr_inventory_prod_data_all`, AWS account 220065406231, one inventory snapshot (dt = 3 days prior to run)

---

## Ask

Identify the PDR-side change deployed **between Thursday Aug 27 and Tuesday Sep 2,
2026 (most likely Aug 27-28)** that cut submitted document volume roughly in half
across the platform. We have strong evidence this is a single systemic event, not
a source-behavior change. Please check deploy/change/infra logs for that window.

## When it started: Friday, August 28, 2026 (high confidence)

Daily document counts (submission date parsed from the S3 key path, NOT
last_modified; Verato-matched; backload and pre-2026-03-11 excluded) show a clean
cliff on Aug 28. Aug 24-27 were fully normal; Aug 28 is the first depressed day,
and the floor holds afterward.

Per-QE daily, Aug 24 - Sep 2 (the onset is the SAME day for every QE):

| day | bronx | healtheconn. | healthix | hixny | rochester | techbd |
|-----|-------|--------------|----------|-------|-----------|--------|
| 08-24 Mon | 145,822 | 589,158 | 774,016 | 220,526 | 168,410 | 170,281 |
| 08-25 Tue | 166,461 | 618,551 | 851,417 | 235,767 | 126,797 | 180,051 |
| 08-26 Wed | 98,690 | 580,218 | 848,732 | 240,645 | 106,936 | 177,742 |
| 08-27 Thu | 92,100 | 574,836 | 716,801 | 191,640 | 121,474 | 160,570 |
| **08-28 Fri** | **84,743** | **273,669** | **381,720** | **104,085** | **55,594** | **80,671** |
| 08-29 Sat | 52,853 | 116,214 | 163,220 | 49,776 | 41,121 | 38,166 |
| 08-30 Sun | 43,538 | 97,328 | 135,436 | 36,258 | 36,845 | 28,281 |
| 08-31 Mon | 80,351 | 291,233 | 396,472 | 89,718 | 36,853 | 85,736 |
| 09-01 Tue | 79,313 | 310,871 | 435,384 | 126,768 | 75,510 | 78,890 |
| 09-02 Wed | 80,602 | 298,435 | 426,247 | 112,225 | 23,471 | 81,309 |

Evidence it is Aug 28 (not Sep 1, not gradual):
- Aug 27 (Thu) is a normal weekday for every QE; Aug 28 (Fri) drops ~50% for
  every QE on the same day. Monday-over-Monday confirms it: Aug 24 vs Aug 31,
  healtheconnections 589K -> 291K, healthix 774K -> 396K (~50% each).
- It is a step change on one day, not a gradual slide.

## It was broad - all QEs, not Healthix alone

Weekday averages, August baseline vs the Sep 1-22 depressed window:

| QE | Aug/wd | Sep 1-22/wd | % of Aug |
|----|--------|-------------|----------|
| bronx | 127,862 | 60,984 | 48% |
| healtheconnections | 479,518 | 367,620 | 77% |
| healthix | 639,102 | 409,171 | 64% |
| hixny | 166,732 | 165,186 | 99% (avg) |
| rochester | 95,272 | 64,016 | 67% |
| techbd | 141,357 | 90,930 | 64% |

- Note on Healthix: Healthix is ~half of PDR volume and has the most sources, so
  it dominates the ABSOLUTE decline - that is expected and not itself a clue. The
  important point is the drop is NOT Healthix-specific.
- hixny's monthly average looks flat (99%), but the daily table shows hixny ALSO
  dropped on Aug 28 (192K -> 104K); it simply RECOVERED faster than the others.
  That difference in recovery speed is a useful lead (what is different about
  hixny's path/connector that let it recover in days while others stayed down ~3
  weeks?).

## It hit small, medium, AND large sources equally (key diagnostic)

Each source classified by its own pre-event volume (Aug 24-27 weekday avg), then
compared to post-event (Sep 1-4 weekday avg):

| Source size tier | Sources | pre/wd | post/wd | % retained | # down >25% |
|------------------|---------|--------|---------|------------|-------------|
| large (>=5000/wd) | 61 | 1,432,267 | 721,034 | 50% | 60 of 61 |
| medium (500-4999/wd) | 277 | 404,042 | 206,110 | 51% | 258 of 277 |
| small (1-499/wd) | 3,242 | 203,102 | 95,805 | 47% | 2,741 of 3,242 |

- The ~50% loss is **uniform across every size tier** and hits **nearly every
  source** (~3,580 sources of all sizes dropped together on the same day).
- A clean, indiscriminate ~50% haircut applied to thousands of unrelated sources
  of every size, simultaneously, is the fingerprint of a **systemic pipeline
  loss**, not sources choosing to send less.

## What the facts point to (hypotheses for PDR eng)

The magnitude (~half) + breadth (all sizes, all QEs, one day) suggests a change
that dropped roughly half of the ingestion/processing capacity or messages, e.g.:
- One of two redundant ingestion paths / workers / consumers failing or being
  removed on Aug 28.
- A routing / partitioning change where ~half of partitions or a consumer group
  stopped landing documents.
- A new filter, sampling, or dedupe step introduced on Aug 28 that silently
  dropped ~half of writes.
- A change that affected most feeds but from which hixny's path was able to
  recover quickly (connector/retry behavior difference).

## Duration & recovery

- Depressed window: ~Aug 28 through ~Sep 22 (about 3.5 weeks).
- Recovery begins ~Sep 23, with a catch-up surge Sep 25 - Oct 6 (volumes above
  normal as the backlog of the depressed period was replayed), then settles back
  to the pre-event normal range from ~Oct 7 onward.
- As of late October, volume is back to the pre-Aug-28 baseline.

## How much was caught up vs. still unaccounted for (~HALF not yet accounted for)

We estimated expected volume from a clean pre-event baseline (Aug 10-27, averaged
by day-of-week so weekday/weekend is handled), then measured the shortfall during
the depression and the excess (catch-up) during the recovery:

| Window | Expected | Actual | Gap |
|--------|----------|--------|-----|
| Depression (Aug 28 - Sep 22) | ~37.3M | ~24.9M | **shortfall ~12.4M** |
| Recovery (Sep 23 - Oct 31) | ~57.1M | ~63.3M | **excess (catch-up) ~6.2M** |

- The catch-up accounts for **~6.2M of the ~12.4M shortfall = roughly 50% of the gap**.
- **Net: ~6.2M documents (~50% of the shortfall) are NOT YET ACCOUNTED FOR** in
  this analysis - i.e. they do not appear, dated to the depression window, under
  the expected assigning-authority path in the inventory we examined.
- In other words: expected volume for the window was ~12.4M documents higher than
  what we see; the catch-up surge accounts for about half; the other half is
  unexplained by this analysis and needs PDR engineering to locate.

IMPORTANT - this is NOT a claim that the data is permanently lost. We can only say
these documents are not present where/when we looked. They may well exist, for
example:
- written under a DIFFERENT assigning-authority path / misrouted to another
  folder,
- stored under a different path date than the clinical/submission date we parse,
- in sources we excluded (orphans not in Verato, or backload paths),
- or still pending replay beyond the snapshot we read.
Confirming where these ~6.2M documents are (or whether they were truly dropped)
is a key part of this investigation.

Caveats on this estimate:
- Assumes volume would have continued at the pre-event (Aug 10-27) rate. August
  was a strong period, so this baseline is reasonable but could be slightly high.
- Recovery is measured through the snapshot edge (Oct 31); a small amount of
  additional replay beyond the snapshot would raise the accounted-for share.
- Scope matches the rest of this ticket: Verato-matched sources only, backload
  excluded, pre-2026-03-11 excluded, dated by key-path submission date.
- Treat as an approximate central estimate (~50% accounted for), not an exact
  figure.

## Method / reproducibility

- One inventory snapshot only (dt = 3 days before run).
- Dated by submission date parsed from the key path `<type>/YYYY/Mon/DD/`, NOT
  last_modified_date (last_modified is re-stamped by routine S3 attribute
  updates - unreliable).
- Verato-matched sources only (orphans excluded); backload excluded; pre-2026-03-11
  excluded. See rules.md.
- Queries in GitHub (repo root https://github.com/rsxmjb234/SQLForS3InventoryOfPDR):
  - [Source-Detail-By-Day.sql](https://github.com/rsxmjb234/SQLForS3InventoryOfPDR/blob/main/QE%20Funding%20Agreement%20Queries/CountByMonthForPayment/Troubleshooting%20SQL/Source-Detail-By-Day.sql)
  - [VolumeDecline-PerQE-CCD-TRN-BySubmissionMonth.sql](https://github.com/rsxmjb234/SQLForS3InventoryOfPDR/blob/main/QE%20Funding%20Agreement%20Queries/CountByMonthForPayment/Troubleshooting%20SQL/VolumeDecline-PerQE-CCD-TRN-BySubmissionMonth.sql)
  - [SystemWide-DailyTotals-FindSpikeDays.sql](https://github.com/rsxmjb234/SQLForS3InventoryOfPDR/blob/main/QE%20Funding%20Agreement%20Queries/CountByMonthForPayment/Troubleshooting%20SQL/SystemWide-DailyTotals-FindSpikeDays.sql)
