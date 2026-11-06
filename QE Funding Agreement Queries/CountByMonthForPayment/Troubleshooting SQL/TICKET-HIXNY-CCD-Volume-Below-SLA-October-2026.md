# [CLARIFICATION REQUESTED] HIXNY CCD October 2026 flagged by baseline formula; driven by a September spike in HEC* sources

**To:** Hixny (HIE operations / data submission team)
**From:** NYeC PDR Analytics
**Date:** November 4, 2026
**Type:** Funding-agreement volume variance review
**Data type in scope:** CCD
**Period in scope:** October 2026
**Reporting source:** Athena `pdr_inventory.pdr_inventory_prod_data_all`
(prod S3 inventory), single snapshot, AWS account 220065406231

---

## 1. Summary

Applied literally, the funding-agreement formula flags Hixny's **October 2026
CCD volume at 86% of baseline**, which is below the 90% threshold.

Our review shows this flag is **caused by the baseline, not by a drop in normal
Hixny submissions.** The baseline (average of August and September) is inflated
by a one-time September surge from a cluster of 161 `HEC*` assigning
authorities. Excluding that cluster, Hixny's remaining CCD sources submitted
**106% of their own August/September average in October** (2.15M vs 2.02M).

We are not asserting an outage. We need Hixny to explain the September `HEC*`
surge so we can decide how the baseline should be treated under the agreement.

Rochester Regional (RRH*) and Westchester Medical (WMC*) have been removed from
every figure in this notice, by prior agreement.

---

## 2. Funding-agreement language

> "The total volume of data submitted is expected to remain consistent month to
> month. For purposes of performance monitoring, each QE will be required to
> submit, at a minimum the aggregate amount of data; NYeC will assess this using
> a rolling two-month average of submitted volume, by data type, as the
> 'baseline.' Beginning June 15th (and monthly thereafter), NYeC will inform
> each QE of its baseline. If, for a full calendar month, a QE's submitted
> volume is more than 10% below its baseline, and the variance is not
> attributable to expected changes (e.g., participant onboarding/offboarding or
> other agreed-upon adjustments), the variance will be considered a PDR outage."

October's CCD baseline is the average of Hixny's August and September CCD
volume.

---

## 3. The formula result (Hixny CCD, RRH/WMC removed)

| Month | Hixny CCD | Role |
|-------|-----------|------|
| Aug 2026 | 2,047,567 | baseline input |
| Sep 2026 | 4,396,873 | baseline input (inflated by `HEC*`, see §4) |
| **Oct 2026** | **2,758,672** | **month in scope** |

| Item | Value |
|------|-------|
| Baseline = avg(Aug, Sep) = (2,047,567 + 4,396,873) / 2 | **3,222,220** |
| October actual | 2,758,672 |
| October as % of baseline | **86%** |
| 90% threshold | 2,899,998 |
| Formula result | **Below threshold** |

For context, Hixny's CCD volume in June and July was 2,111,187 and 2,007,317.
October (2,758,672) is **above** that normal range. The formula flags October
only because September was abnormally high.

---

## 4. Where the variance comes from

We split Hixny's CCD volume into the `HEC*` assigning authorities (161 sources)
and everything else (593 sources):

| Month | `HEC*` sources | All other sources | Total |
|-------|----------------|-------------------|-------|
| Jun | 42,400 | 2,068,787 | 2,111,187 |
| Jul | 58,456 | 1,948,861 | 2,007,317 |
| Aug | 46,600 | 2,000,967 | 2,047,567 |
| **Sep** | **2,356,138** | 2,040,735 | 4,396,873 |
| Oct | 609,209 | 2,149,463 | 2,758,672 |

- **`HEC*` sources:** about 40-60K per month through August, then 2.36M in
  September, then 609K in October. This one cluster accounts for the entire
  September surge and the October "drop."
- **All other sources:** steady at 1.95-2.07M per month and 2.15M in October.
  Against their own August/September average (2,020,851), October is **106%**.

Largest `HEC*` sources (monthly CCD counts):

| Assigning authority | Aug | Sep | Oct |
|---------------------|-----|-----|-----|
| HECG | 3,269 | 535,778 | 184,657 |
| HECUHS | 2,709 | 326,114 | 100,875 |
| HECAMP | 1,413 | 263,116 | 45,932 |
| HECUMU | 12,790 | 209,924 | 32,093 |
| HECMVHS | 1,629 | 177,602 | 26,942 |
| HECTSJHHC | 989 | 160,622 | 37,056 |
| HECFCMG | 429 | 71,522 | 18,482 |
| HECCNYC | 348 | 55,099 | 7,456 |

Largest other sources, with October as a percentage of each source's rolling
two-month average (August and September):

| Assigning authority | Aug | Sep | Oct | Rolling 2-mo avg | Oct % of rolling |
|---------------------|-----|-----|-----|------------------|------------------|
| CCPDOC | 193,057 | 203,537 | 220,880 | 198,297 | 111% |
| SPHPMONITORDOC | 113,560 | 136,667 | 133,403 | 125,114 | 107% |
| SPHPSJHDOC | 94,424 | 92,959 | 89,378 | 93,692 | 95% |
| MIBDOC | 78,729 | 83,975 | 88,658 | 81,352 | 109% |
| 1336193838 | 81,108 | 79,919 | 95,385 | 80,514 | 118% |
| 4965 | 59,420 | 60,527 | 70,000 | 59,974 | 117% |
| CITIADVOC | 50,208 | 58,544 | 52,447 | 54,376 | 96% |
| 7343 | 52,843 | 54,393 | 57,833 | 53,618 | 108% |
| 2904 | 55,171 | 48,986 | 57,822 | 52,079 | 111% |
| ALBANYENT | 52,311 | 38,400 | 52,338 | 45,356 | 115% |
| HHHN | 40,579 | 42,426 | 45,106 | 41,503 | 109% |
| ORTHONY | 31,293 | 32,286 | 29,323 | 31,790 | 92% |

Of the 581 non-`HEC*` sources that had volume in August or September, 119
(about 20%) were below 90% of their own average in October. The other sources
were at or above it. This is ordinary source-to-source variation, not a
platform-wide decline.

Full per-source detail is attached as
`results-hixny-ccd-source-drilldown-Aug-Sep-Oct.csv` (columns include Jun-Oct
counts, the rolling two-month average and October as a percentage of it).

---

## 5. What we need from Hixny

1. **Explain the September `HEC*` surge.** 161 `HEC*` assigning authorities went
   from roughly 47K CCDs in August to 2.36M in September, then 609K in October.
   Was this a backfill, a re-submission, onboarding of new participants, or a
   re-routing of sources into the Hixny bucket? Is any of it expected to
   continue?
2. **Confirm whether the `HEC*` volume is expected, recurring volume.** The
   answer decides whether the September baseline should be adjusted, for
   example as a one-time event outside "submitted volume," or treated as
   participant onboarding.
3. **Confirm there was no change to normal Hixny feeds in October.** Our data
   shows none (the remaining sources are at 106% of baseline), but we want
   Hixny to confirm.

Until we have Hixny's answer on item 1, NYeC is treating October as **under
review** rather than as a PDR outage.

---

## 6. Method / reproducibility

- Source: one recent complete S3 inventory snapshot of
  `pdr_inventory.pdr_inventory_prod_data_all` (bucket `nyec-pdr-prod-hixny*`).
- CCD identified by the `ccd` path segment in the S3 key.
- Submission date parsed from the key path `<AA>/ccd/YYYY/Mon/DD/...`, not
  `last_modified_date` (which is re-stamped by routine S3 attribute updates).
- Backload data is excluded (keys under a `backload/` prefix).
- `processed/` and `error/` objects are excluded. Per Dan Ruppert's analysis
  they are duplicate copies of objects that also exist at the original root
  path, left by S3 cleanups. We confirmed this: de-duplicating on the canonical
  key gives exactly the same counts as excluding those prefixes.
- Data before 2026-03-11 is excluded (header-only era).
- Only sources present in the Verato export (`lookup_verato_aa`) are counted.
- Rochester Regional Health (RRH*) and Westchester Medical Center (WMC*) are
  removed from every query and table in this notice. That data is supplied by
  another designated HIN and is set aside by agreement.
- Baseline = rolling two-month average of submitted CCD volume (August and
  September), per the funding agreement. Per-source percentages use the same
  rolling two-month average.

**Attachments / query artifacts:**
- `results-hixny-ccd-source-drilldown-Aug-Sep-Oct.csv` - per-source Jun-Oct.
- Query of record: `QE Funding Agreement Queries/CountByMonthForPayment/Monthly-VolumneByQEByDataType.sql`

---

## 7. Next steps

1. Hixny to respond to §5.
2. NYeC and Hixny to agree how the September `HEC*` volume is treated in the
   baseline.
3. NYeC to re-run October against the agreed baseline and close or escalate.

Please acknowledge receipt and respond by **[DATE - suggest 5 business days]**.
