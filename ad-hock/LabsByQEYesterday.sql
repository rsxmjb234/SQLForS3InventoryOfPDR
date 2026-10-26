/*
Expected cost/run: ~$0.06 (single inventory day, ~12 GB @ $5/TB)
Expected runtime: ~30 seconds

Goal:
- Count lab documents by QE for yesterday's activity.
- Labs are identified by the 'lab' path segment in the S3 key
  (e.g. BXLEB/lab/2026/Oct/09/20/...hl7) — see rules.md.
- Uses the single day 3 days ago (inventory-complete), excludes backlog.

Output: qe, lab_count
*/

WITH config AS (
    SELECT
        3 AS inventory_lag_days,            -- single day = 3 days ago (complete snapshot)
        2 AS inventory_snapshot_offset_days
),
params AS (
    SELECT
        date_add('day', -c.inventory_lag_days, current_date) AS target_day,
        CAST(date_add('day', -c.inventory_lag_days, current_date) AS timestamp) AS day_start_ts,
        CAST(date_add('day', -(c.inventory_lag_days - 1), current_date) AS timestamp) AS day_end_ts,
        date_format(
            date_add('day', c.inventory_snapshot_offset_days,
                     date_add('day', -c.inventory_lag_days, current_date)),
            '%Y-%m-%d-01-00'
        ) AS dt_target_partition
    FROM config c
)

SELECT
    regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS qe,
    count(*) AS lab_count
FROM pdr_inventory.pdr_inventory_prod_data_all i
JOIN params p
    ON i.dt = p.dt_target_partition
    AND i.last_modified_date >= p.day_start_ts
    AND i.last_modified_date < p.day_end_ts
WHERE
    i.bucket LIKE 'nyec-pdr-prod-%'
    AND i.is_latest = true
    AND coalesce(i.is_delete_marker, false) = false
    -- PDR data contributed before 2026-03-11 was only the HEADER information, not the clinical document; exclude it.
    AND i.last_modified_date >= timestamp '2026-03-11 00:00:00'
    AND NOT regexp_like(lower(i.key), '(^|/)backload(/|$)')
    AND regexp_like(lower(i.key), '(^|/)lab(/|$)')
GROUP BY 1
ORDER BY lab_count DESC;
