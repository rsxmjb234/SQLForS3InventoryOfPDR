# Requirements: Understand the Scale of the PDR

## Purpose

The SQL query supplies a small, reliable set of raw inventory metrics. An LLM uses those metrics to write a plain-language summary of PDR volume, intake, backlog, and approximate storage growth.

The query should return data, not formatted sentences. Do not abbreviate counts, round values, build narrative strings, or convert bytes to GB in SQL.

## Snapshot Comparison

- Use the latest complete inventory snapshot from 4 days before the query run date.
- Compare it with the inventory snapshot from 14 days before the query run date.
- These snapshots are 10 days apart. Calculate average daily change as `(count at -4 days - count at -14 days) / 10`.
- Apply the comparison separately for each QE, document type, and load type.
- Include both the human-readable snapshot dates and the actual `dt` partition values in the output. Do not silently shift the requested snapshots with an undocumented offset.

## Documents to Count

Read active objects from `pdr_inventory.pdr_inventory_prod_data_all`:

- Include PDR production buckets and latest object versions.
- Exclude delete markers.
- Classify document type from the key path: `CCD`, `TRN`, or `LAB`.
- Classify load type as `BACKLOG` when the key contains the `/backload/` path segment; classify other matching documents as `REAL-TIME`.
- Exclude documents with `last_modified_date` before `2026-03-11 00:00:00`.
- Exclude orphan sources that do not match `pdr_inventory.lookup_verato_aa`. Normalize assigning authorities consistently: remove `.DUPLICATE` suffixes, treat underscores as spaces for BRONX, and compare case-insensitively.

## Raw Output

Return one row for each `QE × document type × load type` combination. Include zero-count combinations when practical so missing categories are distinguishable from missing data.

Required columns:

| Column | Meaning |
| --- | --- |
| `run_date` | Date the report was run |
| `recent_snapshot_date` | Date represented by the snapshot 4 days before the run date |
| `recent_dt` | Inventory partition used for the recent snapshot |
| `comparison_snapshot_date` | Date represented by the snapshot 14 days before the run date |
| `comparison_dt` | Inventory partition used for the comparison snapshot |
| `qe` | PDR QE/bucket name |
| `doc_type` | `CCD`, `TRN`, or `LAB` |
| `load_type` | `REAL-TIME` or `BACKLOG` |
| `recent_document_count` | Active qualifying documents in the recent snapshot |
| `comparison_document_count` | Active qualifying documents in the comparison snapshot |
| `recent_total_size_bytes` | Sum of object sizes in the recent snapshot, in bytes |
| `recent_average_size_bytes` | Average object size in the recent snapshot, in bytes |
| `comparison_total_size_bytes` | Sum of object sizes in the comparison snapshot, in bytes |
| `comparison_average_size_bytes` | Average object size in the comparison snapshot, in bytes |
| `recent_first_arrival_date` | Earliest qualifying `last_modified_date` date for this group in the recent snapshot |
| `recent_last_arrival_date` | Latest qualifying `last_modified_date` date for this group in the recent snapshot |
| `recent_arrivals_last_3_days` | Qualifying documents with `last_modified_date` in the three calendar days ending on the recent snapshot date; report this for backlog groups |

Keep size values in bytes and counts as numeric values. Do not put units or explanatory text inside numeric fields. Use `NULL` for a metric that does not apply and `0` when the applicable count is zero.

## LLM Summary Guidance

- Report recent total documents, split by `doc_type` and `load_type`; also show real-time and backlog totals separately.
- Estimate daily intake from the two snapshot counts using the 10-day formula above. Show real-time and backlog rates separately, and break rates out by document type where useful.
- Treat backlog as included in today's stored inventory but as a completed, one-time load with no future growth. Use real-time rates only for forward projections.
- For a one-year document-count projection, start with the recent snapshot count (including backlog) and add 365 days of real-time daily intake by document type. Do not add future backlog intake.
- Estimate monthly S3 growth by document type from real-time daily intake and recent real-time average size. Estimate 12-month S3 spend from the current stored baseline plus real-time-only future growth.
- Use recent byte totals for the current-storage baseline and recent average byte sizes for size descriptions. Convert or format units only when writing the summary; keep those conversions out of the SQL.
- Include the first and last backlog arrival dates, the backlog arrivals in the final three days of the recent snapshot, and the first lab arrival date.
- If estimating S3 cost, state the assumptions: S3 Standard at `$0.023 per GB-month`, no cross-region replication, and whether the approximate `1.2x` request/overhead factor is applied. Keep the underlying size data in bytes.
- Identify the snapshot dates and the `2026-03-11` data cutoff in the summary. Do not imply that the daily rate is a direct event log; it is an estimate from two inventory snapshots.

## Out of Scope

- Producing polished prose or abbreviations in SQL.
- Converting bytes to GB or embedding conversion constants in the query.
- Projecting future backlog intake.
- Counting orphan sources or documents before the cutoff.