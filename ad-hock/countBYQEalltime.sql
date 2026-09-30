/*
Expected cost/run: ~$3-5 (single snapshot partition, but the full standing
  population of ~531M documents is large). Metadata columns only.
Expected runtime: ~2-3 minutes

Goal:
- Count ALL documents currently in the PDR, by QE.
- Includes backlog AND real-time (every document type, every path).
- This is the total standing population, not a daily submission count.

CRITICAL — single snapshot only:
- pdr_inventory_prod_data_all is partitioned by 'dt' (daily snapshot).
- Each partition is a FULL snapshot of the whole bucket, so a document repeats
  in every snapshot. To count the true population you MUST pin to ONE snapshot
  partition. (See DiagnoseReportOfBillionsOfInventory for the full explanation.)
- We use the snapshot from 4 days ago, which has all the data we need and is
  guaranteed complete.

How to use:
- Run as-is. One row per QE with total document count.
*/

WITH latest_snapshot AS (
    SELECT date_format(date_add('day', -4, current_date), '%Y-%m-%d-01-00') AS dt_partition
)

SELECT
    regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS qe,
    count(*) AS total_documents,
    count_if(regexp_like(lower(i.key), '(^|/)ccd(/|$)')) AS ccd_count,
    count_if(regexp_like(lower(i.key), '(^|/)trn(/|$)')) AS trn_count,
    count_if(regexp_like(lower(i.key), '(^|/)oru(/|$)')) AS oru_count,
    count_if(regexp_like(lower(i.key), '(^|/)backload(/|$)')) AS backlog_count
FROM pdr_inventory.pdr_inventory_prod_data_all i
CROSS JOIN latest_snapshot s
WHERE i.dt = s.dt_partition
  AND i.bucket LIKE 'nyec-pdr-prod-%'
  AND i.is_latest = true
  AND coalesce(i.is_delete_marker, false) = false
  -- PDR data contributed before 2026-03-11 was only the HEADER information, not the clinical document; exclude it.
  AND i.last_modified_date >= timestamp '2026-03-11 00:00:00'
GROUP BY 1
ORDER BY total_documents DESC;
