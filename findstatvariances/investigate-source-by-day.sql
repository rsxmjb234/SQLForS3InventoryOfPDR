/*
Expected cost/run: ~$0.95 (194 GB scanned @ $5/TB for 20 days)
Expected runtime: ~2 minutes

Why this query exists:
- When the variance report flags a source as having a multi-day outage,
  this query lets you drill in and see day-by-day detail for that source.
- Shows daily doc counts by type (CCD, TRN, ORU) alongside expected baselines
  so you can pinpoint exactly when an outage started and ended.
- The source list uses IN(...) so you can easily add/remove sources to research.

How to use:
- Update the source_list IN clause to include the sources you want to investigate.
- Adjust lookback_days as needed.
- Results show one row per source per day per data type.
*/

WITH config AS (
    SELECT
        20 AS lookback_days,                -- << CHANGE THIS to adjust how many days to look back
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
),

-- << ADD OR REMOVE SOURCES HERE >>
source_list AS (
    SELECT assigning_authority
    FROM (VALUES ('AMHSAMCH'), ('CMHAMHS'),('SHAMHS'), ('MMC')) AS t(assigning_authority)
),

daily_activity AS (
    SELECT
        p.target_day AS day,
        CASE
            WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error', 'backload')
            THEN split_part(i.key, '/', 2)
            ELSE split_part(i.key, '/', 1)
        END AS source,
        regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS qe,
        CASE
            WHEN regexp_like(lower(i.key), '(^|/)ccd(/|$)') THEN 'CCD'
            WHEN regexp_like(lower(i.key), '(^|/)trn(/|$)') THEN 'TRN'
            WHEN regexp_like(lower(i.key), '(^|/)oru(/|$)') THEN 'ORU'
        END AS data_type
    FROM pdr_inventory.pdr_inventory_prod_data_all i
    JOIN params p
        ON i.dt = p.dt_target_partition
        AND i.last_modified_date >= p.day_start_ts
        AND i.last_modified_date < p.day_end_ts
    WHERE
        i.bucket LIKE 'nyec-pdr-prod-%'
        AND i.is_latest = true
        AND coalesce(i.is_delete_marker, false) = false
        AND (
            regexp_like(lower(i.key), '(^|/)ccd(/|$)')
            OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
            OR regexp_like(lower(i.key), '(^|/)oru(/|$)')
        )
        AND upper(
            CASE
                WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error', 'backload')
                THEN split_part(i.key, '/', 2)
                ELSE split_part(i.key, '/', 1)
            END
        ) IN (SELECT upper(assigning_authority) FROM source_list)
        AND NOT regexp_like(lower(i.key), '(^|/)backload/')
),

-- Create every source × day × data_type combination so zero days are visible
expected AS (
    SELECT
        d.target_day AS day,
        s.assigning_authority AS source,
        dt.data_type
    FROM days d
    CROSS JOIN source_list s
    CROSS JOIN (VALUES ('CCD'), ('TRN'), ('ORU')) AS dt(data_type)
)

SELECT
    date_format(e.day, '%Y-%m-%d') AS day,
    CASE
        WHEN day_of_week(e.day) IN (6, 7) THEN 'weekend'
        ELSE 'Weekday'
    END AS day_type,
    e.source,
    e.data_type,
    coalesce(a.doc_count, 0) AS doc_count,
    a.qe
FROM expected e
LEFT JOIN (
    SELECT
        day,
        source,
        data_type,
        array_join(array_sort(array_distinct(array_agg(qe))), ', ') AS qe,
        count(*) AS doc_count
    FROM daily_activity
    WHERE data_type IS NOT NULL
    GROUP BY 1, 2, 3
) a
    ON e.day = a.day
    AND upper(e.source) = upper(a.source)
    AND e.data_type = a.data_type
ORDER BY e.source ASC, e.day ASC, e.data_type ASC;
