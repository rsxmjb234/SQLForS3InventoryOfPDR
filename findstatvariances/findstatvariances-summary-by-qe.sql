/*
Expected cost/run: ~$0.95 (194.69 GB scanned @ $5/TB)
Expected runtime: ~2 minutes

Goal:
- Produce an actionable summary of variance data grouped by QE.
- For each QE + source + metric, compute:
    - Total days with anomalous submissions
    - Days at exactly zero
    - First and last anomalous date (outage window)
    - Whether the issue is still ongoing (most recent day in range is anomalous)
    - A severity label: Critical / Warning / Watch
- Designed to be sliced by QE and shared with each QE team for follow-up.

Uses the same underlying logic as findstatvariances.sql.
*/

WITH config AS (
    SELECT
        10 AS lookback_days,                -- << CHANGE THIS to adjust how many days to look back
        3  AS inventory_lag_days,           -- days to skip for inventory freshness
        2  AS inventory_snapshot_offset_days,
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
        AND NOT regexp_like(lower(i.key), '(^|/)backload/')
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

-- Combine CCD + TRN variance detection into one set
variances AS (
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
      AND s.mean_value >= (SELECT min_expected_average FROM config)
      AND coalesce(g.ccd_submissions, 0) < s.lower_2stdev

    UNION ALL

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
      AND s.mean_value >= (SELECT min_expected_average FROM config)
      AND coalesce(g.trn_submissions, 0) < s.lower_2stdev
),

-- Summarize per QE / source / metric
summary AS (
    SELECT
        qe,
        source,
        metric,
        count(*)                                        AS days_anomalous,
        count_if(actual_value = 0)                      AS days_at_zero,
        min(day)                                        AS first_anomaly_date,
        max(day)                                        AS last_anomaly_date,
        CAST(round(avg(expected_average)) AS bigint)     AS expected_daily_avg,
        CAST(round(avg(actual_value)) AS bigint)         AS actual_avg_during_anomaly,
        -- Is the most recent anomaly on the last day of the window?
        CASE
            WHEN max(day) = (SELECT end_day FROM date_range)
            THEN 'ONGOING'
            ELSE 'RESOLVED'
        END AS status
    FROM variances
    GROUP BY 1, 2, 3
)

SELECT
    qe,
    source,
    metric,
    days_anomalous,
    days_at_zero,
    date_format(first_anomaly_date, '%Y-%m-%d') AS outage_start,
    date_format(last_anomaly_date, '%Y-%m-%d')  AS outage_end,
    status,
    CASE
        WHEN expected_daily_avg >= 10000 THEN 'SEVERE'
        WHEN status = 'ONGOING' AND days_at_zero >= 3 THEN 'CRITICAL'
        WHEN status = 'ONGOING' AND days_anomalous >= 3 THEN 'CRITICAL'
        WHEN status = 'ONGOING' THEN 'WARNING'
        WHEN days_at_zero >= 3 THEN 'WARNING'
        ELSE 'WATCH'
    END AS severity,
    expected_daily_avg,
    actual_avg_during_anomaly,
    'The source ' || source || ' had '
        || CAST(days_anomalous AS varchar) || ' days anomalous ('
        || CAST(days_at_zero AS varchar) || ' at zero) from '
        || date_format(first_anomaly_date, '%Y-%m-%d') || ' to '
        || date_format(last_anomaly_date, '%Y-%m-%d')
        || '. Expected ~' || CAST(CAST(expected_daily_avg AS bigint) AS varchar)
        || '/day. [' || status || ']'
    AS finding_summary
FROM summary
ORDER BY
    qe ASC,
    CASE severity
        WHEN 'SEVERE' THEN 0
        WHEN 'CRITICAL' THEN 1
        WHEN 'WARNING' THEN 2
        ELSE 3
    END,
    days_at_zero DESC,
    source ASC;
