/*
Expected cost/run: ~$3.50 (700 GB scanned @ $5/TB for 60 days)
Expected runtime: ~5 minutes

Purpose:
- Explore why Dan and Mike keep getting different counts of Assigning
  Authorities depending on when they pull the list.
- Shows the count of DISTINCT assigning authorities contributing CCDs
  per day for the last 60 days.
- Skips the most recent 3 days for inventory freshness.
- If the count varies significantly day to day, it means some sources
  are intermittent (only submit on certain days) and the time window
  matters when building a "complete" list.

Output: day, distinct_aa_count
*/

WITH config AS (
    SELECT
        60 AS lookback_days,                -- << CHANGE THIS
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
    date_format(p.target_day, '%Y-%m-%d') AS day,
    CASE
        WHEN day_of_week(p.target_day) IN (6, 7) THEN 'weekend'
        ELSE 'Weekday'
    END AS day_type,
    count(DISTINCT
        upper(trim(
            CASE
                WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error', 'backload')
                THEN split_part(i.key, '/', 2)
                ELSE split_part(i.key, '/', 1)
            END
        ))
    ) AS distinct_aa_count
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
ORDER BY day ASC;
