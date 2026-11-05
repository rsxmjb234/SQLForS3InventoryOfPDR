# [ACTION REQUIRED] HIXNY CCD submission volume below funding-agreement baseline — October 2026

**To:** Hixny (HIE operations / data submission team)
**From:** NYeC PDR Analytics
**Date:** November 4, 2026
**Type:** Funding-agreement volume variance / PDR outage notice
**Data type in scope:** CCD (Continuity of Care Documents)
**Period in scope:** October 2026
**Reporting source:** Athena `pdr_inventory.pdr_inventory_prod_data_all`
(prod S3 inventory), single snapshot, AWS account 220065406231

---

## 1. Summary

NYeC monitoring shows Hixny's **CCD** submission volume to the PDR in
**October 2026 fell below the funding-agreement baseline** and triggers the
"more than 10% below baseline" threshold. Under the agreement, a sustained
variance of this size that is not attributable to an agreed-upon change is
treated as a PDR outage.

We are notifying Hixny so we can either (a) identify and correct a submission
issue, or (b) document an agreed-upon cause that would exclude the variance.

Our analysis shows two things driving the shortfall: (1) a large **September-only
spike** in a cluster of Hixny sources (the `HEC*` authorities) that did not
repeat in October, which also inflated the rolling baseline, and (2) **moderate
softening (~79–94% of baseline) across Hixny's steady CCD feeds**. No individual
facility went dark. Rochester Regional (RRH) and Westchester Medical (WMC) have
been removed from all figures in this notice by prior agreement.

---

## 2. Funding-agreement language (basis for this notice)

> "The total volume of data submitted is expected to remain consistent month to
> month. For purposes of performance monitoring, each QE will be required to
> submit, at a minimum the aggregate amount of data; NYeC will assess this using
> a rolling two-month average of submitted volume, by data type, as the
> 'baseline.' Beginning June 15th (and monthly thereafter), NYeC will inform
> each QE of its baseline. If, for a full calendar month, a QE's submitted
> volume is more than 10% below its baseline, and the variance is not
> attributable to expected changes (e.g., participant onboarding/offboarding or
> other agreed-upon adjustments), the variance will be considered a PDR outage."

The baseline is a **rolling two-month average of submitted volume, by data
type.** October's CCD baseline is therefore the average of Hixny's August and
September CCD volume.

---

## 3. The variance (Hixny CCD, by month)

Monthly Hixny CCD document counts submitted to the PDR (Verato-matched sources,
backload excluded, dated by the submission date in the S3 key path). Per the
agreement, October's baseline is the **rolling two-month average of the two
immediately preceding months — August and September.**

**Rochester Regional Health (RRH*) and Westchester Medical Center (WMC*) have
been removed from every query behind this ticket** — all monthly totals, the
SLA calculation, and the per-source table in §4. That data is supplied by
another designated HIN, so by agreement it is set aside and is not part of this
variance.

| Month | Hixny CCD (excl. RRH/WMC) | Role |
|-------|---------------------------|------|
| Jun 2026 | 2,898,931 | prior trend |
| Jul 2026 | 3,164,965 | prior trend |
| Aug 2026 | 3,172,241 | baseline input |
| Sep 2026 | 4,396,873 | baseline input (abnormally high — see §5) |
| **Oct 2026** | **2,758,672** | **month in scope** |

**SLA calculation for October (per the contract formula):**

| Item | Value |
|------|-------|
| Rolling 2-month baseline = avg(Aug, Sep) = (3,172,241 + 4,396,873) / 2 | **3,784,557** |
| October actual | 2,758,672 |
| October as % of baseline | **73%** |
| 10%-below threshold (90% of baseline) | 3,406,101 |
| Result | **BELOW baseline — variance flagged** |

October CCD (2,758,672) is below the 90%-of-baseline threshold (3,406,101),
so October is flagged under the agreement. The baseline uses only the rolling
two preceding months (August and September); June and July are shown for trend
context but are not part of the October baseline calculation.

October (2,758,672) is also below Hixny's steady June–August range (≈2.9–3.2M),
so the shortfall is not solely an artifact of the high September — October is
soft against the normal months as well.

> Note for context: September was an unusually high CCD month for Hixny (≈4.4M
> vs a ≈2.9–3.2M June–August range), which raises the rolling baseline. Most of
> that spike came from a specific cluster of sources (see §4); we want to
> understand it with you (§5), since it affects how the baseline should be read.
> Even so, October falls below the contract's 90%-of-baseline threshold, which
> is why we are flagging it.

---

## 4. Where the shortfall is (per source, vs the rolling 2-month average)

For each Hixny CCD assigning authority we computed October as a percentage of
that source's **rolling two-month average (avg of August and September)** — the
same measure the SLA uses — so the per-source view is consistent with §3.
**RRH*/WMC* are removed here too.**

Top Hixny CCD sources by rolling 2-month volume (monthly CCD counts):

| Assigning authority | Aug | Sep | Oct | Rolling 2-mo avg (Aug,Sep) | Oct % of rolling |
|---------------------|-----|-----|-----|----------------------------|------------------|
| HECG | 4,080 | 535,778 | 184,657 | 269,929 | 68% |
| CCPDOC | 276,293 | 203,537 | 220,880 | 239,915 | 92% |
| SPHPMONITORDOC | 200,037 | 136,667 | 133,403 | 168,352 | 79% |
| HECUHS | 3,565 | 326,114 | 100,875 | 164,840 | 61% |
| HECAMP | 1,818 | 263,116 | 45,932 | 132,467 | 35% |
| HECUMU | 24,958 | 209,924 | 32,093 | 117,441 | 27% |
| 1336193838 | 147,989 | 79,919 | 95,385 | 113,954 | 84% |
| SPHPSJHDOC | 130,739 | 92,959 | 89,378 | 111,849 | 80% |
| MIBDOC | 114,617 | 83,975 | 88,658 | 99,296 | 89% |
| HECMVHS | 2,225 | 177,602 | 26,942 | 89,914 | 30% |
| 4965 | 93,222 | 60,527 | 70,000 | 76,875 | 91% |
| CITIADVOC | 93,216 | 58,544 | 52,447 | 75,880 | 69% |
| 7343 | 75,013 | 54,393 | 57,833 | 64,703 | 89% |
| 2904 | 79,651 | 48,986 | 57,822 | 64,319 | 90% |
| HHHN | 72,328 | 42,426 | 45,106 | 57,377 | 79% |
| ALBANYENT | 73,053 | 38,400 | 52,338 | 55,727 | 94% |
| ORTHONY | 52,038 | 32,286 | 29,323 | 42,162 | 70% |

(Full per-source detail for all remaining Hixny CCD sources is attached as
`results-hixny-ccd-source-drilldown-Aug-Sep-Oct.csv`.)

Key observations:
- **Two different things are mixed in the shortfall.**
  1. **A September-only spike in the `HEC*` sources.** HECG, HECUHS, HECAMP,
     HECUMU, HECMVHS and similar were near-zero in August, surged to hundreds of
     thousands in September, then fell back sharply in October. This cluster is
     what pushed Hixny's September total to ≈4.4M and is the main reason the
     rolling baseline is high. We need Hixny to explain this September event
     (see §5) — it looks like a one-time backfill/re-submission rather than
     normal monthly flow.
  2. **Genuine softness in the steady feeds.** The consistently large sources
     (CCPDOC, SPHPMONITORDOC, 1336193838, SPHPSJHDOC, MIBDOC, 4965, etc.) are
     running at roughly **79–94%** of their rolling 2-month average in October —
     a real but moderate decline, not a shut-off.
- **No mass shut-off.** Essentially every source is still submitting in October;
  volumes are lower, not zero.
- **Net effect:** October is below baseline both because the September `HEC*`
  spike did not repeat and because the steady feeds softened. Understanding the
  September `HEC*` event is the single biggest factor in setting a fair baseline.

---

## 5. What we need from Hixny

Please help us determine whether this variance is attributable to an
agreed-upon change or is a correctable submission issue. Specifically:

1. **Any submission/connector/interface change on or around late August –
   September 2026** (routing, filtering, de-duplication, platform migration,
   throttling, credential/endpoint change) that could reduce CCD volume broadly.
2. **The September `HEC*` spike (highest priority).** A cluster of `HEC*`
   sources (HECG, HECUHS, HECAMP, HECUMU, HECMVHS, and similar) were near-zero
   in August, surged to hundreds of thousands of CCDs in September, then dropped
   back in October. This single event raised Hixny's September total to ≈4.4M
   and inflated the rolling baseline. Was this a one-time backfill, re-submission,
   or onboarding event? Knowing this is essential to setting a fair baseline.
3. **The steady feeds at ~79–94%.** The consistently large sources are modestly
   below their rolling average in October. Any connector/interface/throttling
   change in that window that would reduce normal CCD flow?
4. **Any other planned/agreed reductions** beyond RRH/WMC — participant
   offboarding or other adjustments NYeC has agreed to. We have already removed
   Rochester Regional (RRH*) and Westchester Medical (WMC*) from all figures per
   our prior discussion. Our source-level review does **not** show any additional
   specific facilities turning off, so if there is another intended, scoped
   reduction, please identify the facilities so we can reconcile.

---

## 6. Method / reproducibility (for your technical team)

- Source: one recent complete S3 inventory snapshot of
  `pdr_inventory.pdr_inventory_prod_data_all` (bucket `nyec-pdr-prod-hixny*`).
- CCD identified by the `ccd` path segment in the S3 key.
- Submission date parsed from the key path `<AA>/ccd/YYYY/Mon/DD/…`, **not**
  `last_modified_date` (which is re-stamped by routine S3 attribute updates and
  is unreliable for dating submissions).
- **Backlog data is excluded.** Any object tagged/pathed as backload (i.e. keys
  under a `backload/` prefix) is removed; only normal real-time submissions are
  counted. This ensures the comparison reflects ongoing submission volume, not
  one-time historical backloads.
- `processed/` and `error/` workflow-prefix objects **are included** and counted
  as real submissions. (Excluding them is not safe for a month-over-month SLA:
  older months have had many objects moved into `processed/`/`error/` during
  FHIR processing while recent months have not, so excluding those prefixes would
  depress older months relative to recent ones and distort the comparison.)
  pre-2026-03-11 excluded (header-only era).
- Assigning authority parsed per the standard rule (path segment after any
  `processed`/`error`/`backload` prefix).
- **Rochester Regional Health (RRH*) and Westchester Medical Center (WMC*) are
  removed from every query behind this notice** — the monthly totals, the SLA
  calculation in §3, and the per-source table and attached CSV in §4. That data
  is supplied by another designated HIN and is set aside by agreement.
- Baseline = rolling two-month average of submitted CCD volume (August and
  September), per the funding agreement. Per-source percentages in §4 use the
  same rolling two-month average, for consistency with the SLA.

**Attachments / query artifacts:**
- `results-hixny-ccd-source-drilldown-Aug-Sep-Oct.csv` — per-source Aug/Sep/Oct.
- Query of record: `QE Funding Agreement Queries/CountByMonthForPayment/Monthly-VolumneByQEByDataType.sql`

---

## 7. Requested next steps & timeline

1. Hixny to review items in §5 and respond with any known change or
   agreed-upon reduction.
2. If a submission issue is identified, Hixny to remediate and confirm CCD
   volume returns to baseline.
3. If the variance is attributable to an agreed-upon change, NYeC and Hixny to
   document it so the October variance is excluded from the outage determination.

Please acknowledge receipt and provide an initial response by **[DATE — suggest
5 business days]**.
