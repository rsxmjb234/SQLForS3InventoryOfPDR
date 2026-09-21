/*
Expected cost/run: ~$1-2 (scans metadata columns across recent snapshot partitions)
Expected runtime: ~1-2 minutes

QUERY 1 of 3 — Rows per snapshot partition (demonstrates the inflation)

Goal:
- Show the total row count in each daily inventory snapshot partition (dt),
  plus CCD and TRN row counts within each snapshot.

KEY CONCEPT — why someone sees "billions" of records:
- pdr_inventory_prod_data_all is partitioned by 'dt' (the snapshot run date).
- Each dt partition is a FULL snapshot of everything currently in the bucket.
- So a document submitted once shows up in EVERY subsequent daily snapshot.
- Counting the whole table (all dt partitions) multiplies each real document
  by the number of days it has existed = billions of rows.

What to look for:
- Each dt partition should show a similar large total (because each is a
  cumulative snapshot of the whole bucket). Seeing ~the same big number
  repeated per day is the "billions" — it's the same documents counted again
  and again across snapshots, NOT unique daily submissions.
*/

SELECT
    dt AS snapshot_partition,
    count(*) AS total_rows_in_snapshot,
    count_if(regexp_like(lower(key), '(^|/)ccd(/|$)')) AS ccd_rows,
    count_if(regexp_like(lower(key), '(^|/)trn(/|$)')) AS trn_rows
FROM pdr_inventory.pdr_inventory_prod_data_all
WHERE bucket LIKE 'nyec-pdr-prod-%'
  AND is_latest = true
  AND coalesce(is_delete_marker, false) = false
  AND dt >= date_format(date_add('day', -14, current_date), '%Y-%m-%d-01-00')
GROUP BY dt
ORDER BY dt DESC;
