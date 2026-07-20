/*
Goal:
- Average daily backlog document submissions by QE over a configurable period.
- Formula: total backlog docs / number of days in window = avg docs/day
- Ranked slowest to fastest.

Expected cost/run: ~$0.95 (scans ~195 GB @ $5/TB)
Expected runtime: ~2 minutes
*/

WITH config AS (
    SELECT
        5  AS lookback_days,                -- << CHANGE THIS to adjust the window
        3  AS inventory_lag_days,           -- skip recent days for inventory freshness
        2  AS inventory_snapshot_offset_days
),
date_range AS (
    SELECT
        date_add('day', -(c.lookback_days + c.inventory_lag_days - 1), current_date) AS start_day,
        date_add('day', -c.inventory_lag_days, current_date) AS end_day,
        c.inventory_snapshot_offset_days,
        c.lookback_days
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
),

backlog_docs AS (
    SELECT
        regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS qe,
        p.target_day AS day,
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
        AND regexp_like(lower(i.key), '(^|/)backload/')
        AND (
            regexp_like(lower(i.key), '(^|/)ccd(/|$)')
            OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
        )
    GROUP BY 1, 2
)

SELECT
    qe,
    sum(ccd_count)                                          AS total_backlog_ccd,
    sum(trn_count)                                          AS total_backlog_trn,
    (SELECT lookback_days FROM date_range)                  AS days_in_window,
    round(CAST(sum(ccd_count) AS double) / (SELECT lookback_days FROM date_range)) AS avg_ccd_per_day,
    round(CAST(sum(trn_count) AS double) / (SELECT lookback_days FROM date_range)) AS avg_trn_per_day,
    (SELECT CAST(start_day AS varchar) FROM date_range)     AS window_start,
    (SELECT CAST(end_day AS varchar) FROM date_range)       AS window_end
FROM backlog_docs
GROUP BY qe
ORDER BY avg_ccd_per_day ASC, avg_trn_per_day ASC;
