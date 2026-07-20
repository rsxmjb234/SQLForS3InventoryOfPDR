/*
Expected cost/run: ~$1.40 (scans ~280 GB for 30 days @ $5/TB)
Expected runtime: ~2-3 minutes

Goal:
- Compute a statistical baseline (mean, stdev, 2-stdev bounds) for each
  hospital source, by day_type (Weekday/weekend) and metric (CCD/TRN).
- This baseline is used by the findstatvariances queries to detect anomalies.
- ONLY includes hospitals (via hospital_aa_reference join).
- ONLY includes real-time data (backlog is excluded).
- Skips the last 3 days to avoid incomplete inventory data.
- Looks back 30 days for the baseline window.

IMPORTANT — After running:
- Download results as CSV.
- Upload the CSV to: s3://pdr-nyec-local/Lookup-STDEVandAverageForHospitals/
- This overwrites the previous baseline used by the variance detection queries.
- The external table pdr_inventory.lookup_stdev_average_for_hospitals points
  to that S3 location (see maketablesqlforlookup.sql for the DDL).

Output columns match the external table schema:
  assigning_authority, qe, day_type, metric, mean_value, stdev_value,
  sample_days, baseline_start_epoch_day, baseline_end_epoch_day,
  lower_2stdev, upper_2stdev
*/

WITH config AS (
    SELECT
        30 AS lookback_days,                -- << CHANGE THIS to adjust baseline window
        3  AS inventory_lag_days,           -- skip last 3 days for inventory freshness
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
),

typed AS (
    SELECT
        p.target_day AS day,
        regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS qe,
        CASE
            WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error', 'backload')
            THEN split_part(i.key, '/', 2)
            ELSE split_part(i.key, '/', 1)
        END AS assigning_authority,
        CASE
            WHEN regexp_like(lower(i.key), '(^|/)ccd(/|$)') THEN 'CCD'
            WHEN regexp_like(lower(i.key), '(^|/)trn(/|$)') THEN 'TRN'
        END AS doc_type
    FROM pdr_inventory.pdr_inventory_prod_data_all i
    JOIN params p
        ON i.dt = p.dt_target_partition
        AND i.last_modified_date >= p.day_start_ts
        AND i.last_modified_date < p.day_end_ts
    INNER JOIN pdr_inventory.hospital_aa_reference h
        ON upper(
            CASE
                WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error', 'backload')
                THEN split_part(i.key, '/', 2)
                ELSE split_part(i.key, '/', 1)
            END
        ) = upper(h.assigning_authority)
    WHERE
        i.bucket LIKE 'nyec-pdr-prod-%'
        AND i.is_latest = true
        AND coalesce(i.is_delete_marker, false) = false
        -- Exclude backlog
        AND NOT regexp_like(lower(i.key), '(^|/)backload/')
        -- Only CCD and TRN
        AND (
            regexp_like(lower(i.key), '(^|/)ccd(/|$)')
            OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
        )
),

-- Daily counts per source, day_type, metric
daily_counts AS (
    SELECT
        day,
        CASE
            WHEN day_of_week(day) IN (6, 7) THEN 'weekend'
            ELSE 'Weekday'
        END AS day_type,
        assigning_authority,
        array_join(array_sort(array_distinct(array_agg(qe))), ', ') AS qe,
        count_if(doc_type = 'CCD') AS ccd_count,
        count_if(doc_type = 'TRN') AS trn_count
    FROM typed
    WHERE doc_type IS NOT NULL
    GROUP BY 1, 2, 3
),

-- Unpivot into metric rows
metric_rows AS (
    SELECT assigning_authority, qe, day_type, day, 'CCD' AS metric, ccd_count AS daily_value
    FROM daily_counts
    UNION ALL
    SELECT assigning_authority, qe, day_type, day, 'TRN' AS metric, trn_count AS daily_value
    FROM daily_counts
),

-- Compute stats
stats AS (
    SELECT
        assigning_authority,
        qe,
        day_type,
        metric,
        CAST(round(avg(daily_value)) AS bigint)                          AS mean_value,
        CAST(coalesce(round(stddev(daily_value)), 0) AS bigint)          AS stdev_value,
        count(*)                                                          AS sample_days,
        date_diff('day', DATE '1970-01-01', min(day))                     AS baseline_start_epoch_day,
        date_diff('day', DATE '1970-01-01', max(day))                     AS baseline_end_epoch_day
    FROM metric_rows
    GROUP BY 1, 2, 3, 4
)

SELECT
    assigning_authority,
    qe,
    day_type,
    metric,
    mean_value,
    stdev_value,
    sample_days,
    baseline_start_epoch_day,
    baseline_end_epoch_day,
    CAST(greatest(0, mean_value - 2 * coalesce(stdev_value, 0)) AS bigint) AS lower_2stdev,
    CAST(mean_value + 2 * coalesce(stdev_value, 0) AS bigint)              AS upper_2stdev
FROM stats
ORDER BY assigning_authority ASC, metric ASC, day_type ASC;
