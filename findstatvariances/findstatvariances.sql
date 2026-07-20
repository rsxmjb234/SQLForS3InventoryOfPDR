/*
Goal:
- Pull hospital-only submission activity over a configurable date range.
- Keep results day-granular (one row set per target day).
- Use inventory_snapshot_offset_days to support delayed inventory partitions
  (set to 2 for a two-day lookback).
- Always strip today, yesterday, and the day before from the range to avoid
  false positives caused by inventory refresh lag.
- Use a LEFT JOIN from all expected hospitals × days so that a hospital
  sending 0 documents is correctly flagged as a variance.

*/

WITH config AS (
    SELECT
        10 AS lookback_days,                -- << CHANGE THIS to adjust how many days to look back
        3  AS inventory_lag_days,           -- days to skip (today/yesterday/day-before) for inventory freshness
        2  AS inventory_snapshot_offset_days,
        'Low' AS variance_filter,           -- << 'Low', 'High', or 'Both'
        50 AS min_expected_average          -- << ignore sources whose expected average is below this
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
        i.bucket,
        regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS qe,

        CASE
            WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error', 'backload')
            THEN split_part(i.key, '/', 2)
            ELSE split_part(i.key, '/', 1)
        END AS assigning_authority,

        CASE
            WHEN regexp_like(lower(i.key), '(^|/)backload/') THEN 'BACKLOAD'
            ELSE 'NON_BACKLOAD'
        END AS load_type,

        CASE
            WHEN regexp_like(lower(i.key), '(^|/)trn(/|$)') THEN 'TRN'
            WHEN regexp_like(lower(i.key), '(^|/)ccd(/|$)') THEN 'CCD'
            WHEN regexp_like(lower(i.key), '(^|/)oru(/|$)') THEN 'ORU'
        END AS doc_type,

        i.last_modified_date,
        i.key
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
        AND (
            regexp_like(lower(i.key), '(^|/)trn(/|$)')
            OR regexp_like(lower(i.key), '(^|/)ccd(/|$)')
            OR regexp_like(lower(i.key), '(^|/)oru(/|$)')
        )
),

grouped AS (
    SELECT
        day,
        CASE
            WHEN day_of_week(day) IN (6, 7) THEN 'weekend'
            ELSE 'Weekday'
        END AS day_type,
        assigning_authority,
        array_join(array_sort(array_distinct(array_agg(qe))), ', ') AS qe,
        count_if(doc_type = 'CCD') AS ccd_submissions,
        count_if(doc_type = 'TRN') AS trn_submissions
    FROM typed
    WHERE doc_type IS NOT NULL
    GROUP BY 1, 2, 3
),

-- Generate every hospital × day combination so we detect zero-submission days
expected AS (
    SELECT
        d.target_day AS day,
        CASE
            WHEN day_of_week(d.target_day) IN (6, 7) THEN 'weekend'
            ELSE 'Weekday'
        END AS day_type,
        h.assigning_authority
    FROM days d
    CROSS JOIN (
        SELECT DISTINCT assigning_authority
        FROM pdr_inventory.hospital_aa_reference
    ) h
),

variances AS (
    -- CCD variance check
    SELECT
        e.day,
        e.day_type,
        e.assigning_authority            AS source,
        s.qe,
        'CCD'                            AS metric,
        coalesce(g.ccd_submissions, 0)   AS actual_value,
        s.mean_value                     AS expected_average,
        s.lower_2stdev                   AS expected_lower_2stdev,
        s.upper_2stdev                   AS expected_upper_2stdev
    FROM expected e
    JOIN pdr_inventory.lookup_stdev_average_for_hospitals s
        ON upper(e.assigning_authority) = upper(s.assigning_authority)
        AND e.day_type = s.day_type
        AND s.metric   = 'CCD'
    LEFT JOIN grouped g
        ON upper(e.assigning_authority) = upper(g.assigning_authority)
        AND e.day = g.day
    WHERE NOT (s.mean_value = 0 AND s.stdev_value = 0)
      AND (
            coalesce(g.ccd_submissions, 0) < s.lower_2stdev
         OR coalesce(g.ccd_submissions, 0) > s.upper_2stdev
      )

    UNION ALL

    -- TRN variance check
    SELECT
        e.day,
        e.day_type,
        e.assigning_authority            AS source,
        s.qe,
        'TRN'                            AS metric,
        coalesce(g.trn_submissions, 0)   AS actual_value,
        s.mean_value                     AS expected_average,
        s.lower_2stdev                   AS expected_lower_2stdev,
        s.upper_2stdev                   AS expected_upper_2stdev
    FROM expected e
    JOIN pdr_inventory.lookup_stdev_average_for_hospitals s
        ON upper(e.assigning_authority) = upper(s.assigning_authority)
        AND e.day_type = s.day_type
        AND s.metric   = 'TRN'
    LEFT JOIN grouped g
        ON upper(e.assigning_authority) = upper(g.assigning_authority)
        AND e.day = g.day
    WHERE NOT (s.mean_value = 0 AND s.stdev_value = 0)
      AND (
            coalesce(g.trn_submissions, 0) < s.lower_2stdev
         OR coalesce(g.trn_submissions, 0) > s.upper_2stdev
      )
)

SELECT
    date_format(v.day, '%Y-%m-%d') AS day,
    v.day_type,
    v.source,
    v.qe,
    v.metric,
    v.actual_value,
    v.expected_average,
    v.expected_lower_2stdev,
    v.expected_upper_2stdev,
    CASE
        WHEN v.actual_value > v.expected_upper_2stdev THEN 'High'
        ELSE 'Low'
    END AS variance_direction
FROM variances v
CROSS JOIN config c
WHERE (c.variance_filter = 'Both'
   OR c.variance_filter = CASE
        WHEN v.actual_value > v.expected_upper_2stdev THEN 'High'
        ELSE 'Low'
    END)
  AND v.expected_average >= c.min_expected_average
ORDER BY qe ASC, source ASC, day DESC;
