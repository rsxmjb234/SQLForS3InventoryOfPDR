/*
Expected cost/run: ~$0.59 (118 GB scanned @ $5/TB for 10 days)
Expected runtime: ~1 minute

Goal:
- Find assigning authorities that are contributing very few CCDs to the PDR.
- "Very few" = fewer than 100 total CCDs over a 10-day period.
- These are sources that may not be worth including in large-scale analyses
  (e.g., EHR classification) because their volume is too low to be meaningful.
- Excludes backlog data — only real-time submissions.
- Skips last 3 days for inventory freshness.

How to use:
- Adjust the threshold (HAVING count(*) < 100) if needed.
- Results are ordered by QE, then lowest CCD count first.
*/

WITH config AS (
    SELECT
        10 AS lookback_days,                -- << CHANGE THIS
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
            WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error', 'backload')
            THEN split_part(i.key, '/', 2)
            ELSE split_part(i.key, '/', 1)
        END
    )) AS assigning_authority,
    count(*) AS total_ccds
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
    AND regexp_like(lower(i.key), '(^|/)ccd(/|$)')
GROUP BY 1, 2
HAVING count(*) < 100
ORDER BY qe ASC, total_ccds ASC;
