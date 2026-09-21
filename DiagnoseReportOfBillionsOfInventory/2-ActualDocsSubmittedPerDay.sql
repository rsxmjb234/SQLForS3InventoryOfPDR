/*
Expected cost/run: ~$0.50-1 (single snapshot partition, filtered by submission date)
Expected runtime: ~1 minute

QUERY 2 of 3 — Actual documents SUBMITTED per day (the "real" volume)

Goal:
- Show the true number of documents actually submitted per day.
- Broken out by total, CCD count, and TRN count.

How this differs from Query 1:
- Uses a SINGLE snapshot partition (dt) so documents are NOT counted multiple
  times across daily snapshots.
- Groups by last_modified_date (the day the document was actually submitted),
  not by the snapshot date.
- This is the number that matches the funding-agreement / submission counts.

How to use:
- Adjust the dt partition and the last_modified_date range as needed.
- The dt should be a recent, complete snapshot (today - 1 or - 2).
*/

SELECT
    date_format(last_modified_date, '%Y-%m-%d') AS submission_day,
    count(*) AS total_docs_submitted,
    count_if(regexp_like(lower(key), '(^|/)ccd(/|$)')) AS ccd_count,
    count_if(regexp_like(lower(key), '(^|/)trn(/|$)')) AS trn_count
FROM pdr_inventory.pdr_inventory_prod_data_all
WHERE bucket LIKE 'nyec-pdr-prod-%'
  AND is_latest = true
  AND coalesce(is_delete_marker, false) = false
  -- Single most-recent complete snapshot partition (adjust to a real dt value)
  AND dt = date_format(date_add('day', -1, current_date), '%Y-%m-%d-01-00')
  -- Window of submission days you want to see
  AND last_modified_date >= timestamp '2026-08-01 00:00:00'
  AND last_modified_date <  timestamp '2026-09-01 00:00:00'
GROUP BY date_format(last_modified_date, '%Y-%m-%d')
ORDER BY submission_day DESC;
