# Memo: Investigating the "Billions of Files in the PDR" Concern

**Date:** September 4, 2026
**To:** CIO / Technology Leadership
**From:** PDR Data Analysis Team
**Re:** Whether the Primary Document Repository (PDR) contains billions more files than expected — and how to query it correctly going forward

---

## Executive Summary

A concern was raised that the PDR appears to contain hundreds of millions to billions more files than the volume of clinical documents we actually receive would suggest. We investigated.

**Bottom line:** There is **no data integrity problem.** The "billions" figure is real when you count the raw inventory table, but it is an artifact of how Amazon S3 Inventory works — the same documents are recorded once per daily snapshot, and we retain roughly 112 daily snapshots. Counting across all of them multiplies the true document population by ~112.

- **True document population (one snapshot):** ~531 million documents, with **zero duplication.**
- **Raw table count (all ~112 snapshots combined):** ~59.8 billion rows.
- **Actual daily clinical submissions:** ~1.2 to 7.4 million CCD/TRN documents per day, which is fully consistent with the 531M cumulative total.

The issue is not the data. It is a query that counts every daily snapshot as if it were unique. The fix is a one-line change, described at the end of this memo.

---

## Hypothesis

> The PDR contains hundreds of millions to billions more files than would be expected for the volume of clinical documents (CCD/TRN) actually submitted.

If true, this could indicate orphaned files, runaway duplication, or large volumes of non-clinical content consuming storage and skewing reporting.

---

## Method

We ran three measurements against the inventory table `pdr_inventory.pdr_inventory_prod_data_all`:

1. **Raw table count** across all snapshot partitions.
2. **Single snapshot count** — both total rows and *distinct* documents (bucket + key), to detect duplication within one snapshot.
3. **Actual daily submissions** — using one snapshot partition, filtered by submission date, split into CCD and TRN.

The key structural fact: this table is partitioned by `dt` (a daily snapshot date). **Each partition is a complete copy of the entire bucket on that day.** A document submitted once appears again in every later daily snapshot for as long as it remains in storage.

---

## Results

### Raw count vs. a single snapshot

| Measure | Row Count |
|---|---:|
| ALL snapshots combined (raw table count) | 59,773,117,649 |
| One snapshot partition (total rows) | 530,996,313 |
| One snapshot partition (distinct documents) | 530,996,313 |

- The raw count of **~59.8 billion** is the number that raised the alarm.
- A single snapshot contains **~531 million** documents.
- **Distinct count equals total count** within a snapshot — there is no duplication in the underlying data.
- 59.8B ÷ 531M ≈ **112**, matching the number of daily snapshots retained. The big number is simply ~531M documents counted once per snapshot.

### Actual clinical submissions per day (August 2026, sample)

| Day | Total Submitted | CCD | TRN |
|---|---:|---:|---:|
| 2026-08-26 | 7,401,200 | 6,118,125 | 1,283,075 |
| 2026-08-14 | 4,054,034 | 3,659,126 | 394,908 |
| 2026-08-31 | 1,721,437 | 1,274,402 | 447,035 |
| 2026-08-24 | 1,169,304 | 926,384 | 242,920 |

Daily volumes of 1–7 million valid clinical documents accumulate over time into the ~531M single-snapshot total. The numbers reconcile.

---

## Conclusion

**The hypothesis is rejected as a data problem, though the observation that triggered it is real.**

- Counting the whole table returns ~59.8 billion rows.
- Those are not billions of distinct files — they are ~531 million documents recorded once per daily snapshot across ~112 retained snapshots.
- No duplication exists within any single snapshot.
- Daily submission volumes are consistent with the true document population.

There is no orphaned-file or runaway-duplication issue. The "billions" is a well-understood property of S3 Inventory snapshots.

---

## Why the Concern Arose

The most likely cause is a query that counted the entire inventory table **without restricting to a single daily snapshot (`dt`).** Because each snapshot is a full copy of the bucket, an unfiltered count multiplies the real population by the number of retained snapshots — turning ~531M into ~59.8B. This is an easy and understandable mistake, and the resulting number looks alarming at face value.

Our internal sampling query, `1m_query.sql`, has exactly this gap: it reads from `pdr_inventory_prod_data_all` with no `dt` filter. It happens to still function for random sampling, but it scans all ~112 snapshots — roughly 112× more data than necessary — and any counts derived from it will be inflated.

---

## Recommended Fix — How the Team Should Modify `1m_query.sql`

The correction is small. Add a single-snapshot filter (and a couple of standard hygiene filters) so the query reads **one** daily snapshot instead of all of them.

### 1. Add a single-snapshot filter to the innermost `FROM` clause

In the `split_paths` CTE, the query currently reads:

```sql
FROM pdr_inventory.pdr_inventory_prod_data_all
WHERE key NOT LIKE '%/'
  AND is_latest = true
  AND coalesce(is_delete_marker, false) = false
  AND bucket IN ( ... )
```

Add one line pinning it to a single snapshot partition:

```sql
FROM pdr_inventory.pdr_inventory_prod_data_all
WHERE key NOT LIKE '%/'
  AND is_latest = true
  AND coalesce(is_delete_marker, false) = false
  AND dt = date_format(date_add('day', -1, current_date), '%Y-%m-%d-01-00')   -- << single snapshot only
  AND bucket IN ( ... )
```

That one line is the core fix. It reduces the scan from ~59.8 billion rows to ~531 million and removes the snapshot inflation entirely.

### 2. (Optional) Restrict to a submission window

If the goal is documents submitted in a specific period rather than the entire standing population, also filter on `last_modified_date`:

```sql
  AND last_modified_date >= timestamp '2026-08-01 00:00:00'
  AND last_modified_date <  timestamp '2026-09-01 00:00:00'
```

### 3. (Already correct) Clinical-type filter

The query already isolates CCDs downstream (`WHERE path_parts[file_type_index] = 'ccd'`). No change needed there. To include TRNs, broaden that check to `IN ('ccd','trn')`.

### Standing rule for all PDR inventory queries

To count real clinical content and avoid this trap, every query against the inventory table should include:

```sql
AND dt = <one specific snapshot partition>          -- never aggregate across all dt
AND is_latest = true
AND coalesce(is_delete_marker, false) = false
AND bucket LIKE 'nyec-pdr-prod-%'
AND ( regexp_like(lower(key), '(^|/)ccd(/|$)')
   OR regexp_like(lower(key), '(^|/)trn(/|$)') )   -- valid clinical types only
```

With these filters, counts land in the expected range — on the order of low tens of millions of clinical documents per month — and match our independent measurements (for example, the ~950K CCDs observed in the 1-million-target sampling window).

---

## One-Sentence Takeaway for Leadership

The PDR is healthy; the "billions" number came from counting every daily backup of the same ~531 million documents, and a one-line query change (restrict to a single daily snapshot) makes the reported totals accurate.
