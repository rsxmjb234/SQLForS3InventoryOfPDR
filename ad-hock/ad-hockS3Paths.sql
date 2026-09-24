/*
Expected cost/run: ~$0.59 (118 GB scanned @ $5/TB for 10 days)
Expected runtime: ~1-2 minutes

Goal:
- Count documents per S3 container (bucket) over the last 10 days.
- Shows the bucket-level path someone would be granted AWS rights to
  (e.g., s3://nyec-pdr-prod-bronx/) plus a sample full document path.
- Excludes backlog — only real-time submissions.
- Skips most recent 3 days for inventory freshness; 10-day window.

How to use:
- Run as-is. The bucket_path column is what you grant access to in AWS/IAM.
- doc_count shows the volume in each container over the window.
*/

WITH config AS (
    SELECT
        10 AS lookback_days,                -- << 10-day window
        3  AS inventory_lag_days,           -- start 3 days ago (inventory lag)
        2  AS inventory_snapshot_offset_days
),
date_range AS (
    SELECT
        date_add('day', -(c.lookback_days + c.inventory_lag_days - 1), current_date) AS start_day,
        date_add('day', -c.inventory_lag_days, current_date) AS end_day,
        c.inventory_snapshot_offset_days
    FROM config c
),
days AS (
    SELECT
        d AS target_day
    FROM date_range c
    CROSS JOIN UNNEST(sequence(c.start_day, c.end_day, INTERVAL '1' DAY)) AS t(d)
),
params AS (
    SELECT
        d.target_day,
        CAST(d.target_day AS timestamp) AS day_start_ts,
        CAST(date_add('day', 1, d.target_day) AS timestamp) AS day_end_ts,
        date_format(
            date_add('day', c.inventory_snapshot_offset_days, d.target_day),
            '%Y-%m-%d-01-00'
        ) AS dt_target_partition
    FROM days d
    CROSS JOIN date_range c
)

SELECT
    regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS qe,
    's3://' || i.bucket || '/' AS bucket_path,
    count(*) AS doc_count,
    's3://' || max(i.bucket || '/' || i.key) AS sample_full_s3_path
FROM pdr_inventory.pdr_inventory_prod_data_all i
JOIN params p
    ON i.dt = p.dt_target_partition
    AND i.last_modified_date >= p.day_start_ts
    AND i.last_modified_date < p.day_end_ts
WHERE
    i.bucket LIKE 'nyec-pdr-prod-%'
    AND i.is_latest = true
    AND coalesce(i.is_delete_marker, false) = false
    AND NOT regexp_like(lower(i.key), '(^|/)backload(/|$)')
    AND (
        regexp_like(lower(i.key), '(^|/)ccd(/|$)')
        OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
        OR regexp_like(lower(i.key), '(^|/)oru(/|$)')
    )
GROUP BY i.bucket
ORDER BY doc_count DESC;
