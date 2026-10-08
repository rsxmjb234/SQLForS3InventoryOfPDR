/*
Expected cost/run: ~$0.59 (118 GB scanned @ $5/TB for 10 days)
Expected runtime: ~1-2 minutes

Goal:
- Simple count of CCDs and TRNs by assigning authority.
- Data contributed in the last 10 days only.
- Excludes backlog — real-time submissions only.
- Skips most recent 3 days for inventory freshness.
*/

WITH config AS (
    SELECT
        10 AS lookback_days,                -- << 10-day window
        3  AS inventory_lag_days,
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
    upper(trim(
        CASE
            WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error')
            THEN split_part(i.key, '/', 2)
            ELSE split_part(i.key, '/', 1)
        END
    )) AS assigning_authority,
    count_if(regexp_like(lower(i.key), '(^|/)ccd(/|$)')) AS ccd_count,
    count_if(regexp_like(lower(i.key), '(^|/)trn(/|$)')) AS trn_count
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
    AND (
        regexp_like(lower(i.key), '(^|/)ccd(/|$)')
        OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
    )
GROUP BY 1, 2
ORDER BY assigning_authority ASC;
