/*
Why this query exists:
- The funding agreement requires QEs to maintain consistent monthly submission
  volume. A rolling 2-month average is used as the baseline, and any month that
  drops more than 10% below baseline (without agreed-upon justification) is
  considered a PDR outage.
- This query provides the DAY-LEVEL detail behind the monthly totals so you can:
    1. Show your work — every day's contribution to the monthly total is visible.
    2. Bring into Excel and pivot/filter to investigate drops.
    3. Identify exactly which days drove a shortfall.
- Excludes backload data (only real-time/normal submissions count toward the goal).

Dating:
- Buckets by the TRUE submission date parsed from the key path
  (.../<type>/YYYY/Mon/DD/), NOT last_modified_date. last_modified gets
  re-stamped by metadata changes / bulk rewrites, which falsely moves docs to
  later dates; the key path preserves the real submission date. Because of this,
  NO anomaly-day / bulk-spike-day exclusion is needed.

How to use:
- Set start_month and end_month in config.
- Export results to CSV, open in Excel.
- Pivot: Rows = day, Columns = qe, Values = sum of doc_count.
- Or filter by qe and data_type to drill into a specific concern.
*/

WITH config AS (
    SELECT
        DATE '2026-01-01' AS start_month,       -- << first day of first month
        DATE '2026-07-01' AS end_month,         -- << first day of last month to include
        2 AS inventory_snapshot_offset_days
),
months AS (
    SELECT
        m AS month_start,
        date_add('month', 1, m) AS month_end
    FROM config c
    CROSS JOIN UNNEST(sequence(c.start_month, c.end_month, INTERVAL '1' MONTH)) AS t(m)
),
month_days AS (
    SELECT
        m.month_start,
        d AS target_day,
        date_format(
            date_add('day', c.inventory_snapshot_offset_days, d),
            '%Y-%m-%d-01-00'
        ) AS dt_target_partition
    FROM months m
    CROSS JOIN config c
    CROSS JOIN UNNEST(sequence(m.month_start, date_add('day', -1, m.month_end), INTERVAL '1' DAY)) AS t(d)
),

-- One row per doc, with the TRUE submission date parsed from the key path.
docs AS (
    SELECT
        i.dt,
        regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS qe,
        CASE
            WHEN regexp_like(lower(i.key), '(^|/)ccd(/|$)') THEN 'CCD'
            WHEN regexp_like(lower(i.key), '(^|/)trn(/|$)') THEN 'TRN'
            WHEN regexp_like(lower(i.key), '(^|/)oru(/|$)') THEN 'ORU'
        END AS data_type,
        -- True submission date parsed from the key path: <type>/YYYY/Mon/DD/
        TRY(date_parse(
            regexp_extract(i.key, '(?i)(?:ccd|trn|lab|oru)/(\d{4}/[A-Za-z]{3}/\d{2})/', 1),
            '%Y/%b/%d'
        )) AS submission_date
    FROM pdr_inventory.pdr_inventory_prod_data_all i
    WHERE
        i.bucket LIKE 'nyec-pdr-prod-%'
        AND i.is_latest = true
        AND coalesce(i.is_delete_marker, false) = false
        -- Scan reducer only (re-stamps move dates forward; see rules.md).
        AND i.last_modified_date >= timestamp '2026-03-11 00:00:00'
        -- GLOBAL RULE: exclude processed/ and error/ workflow-prefix objects
        -- (historical FHIR-processing copies; see rules.md). Dropped like the date rule.
        AND NOT regexp_like(lower(i.key), '^(processed|error)/')
        -- Exclude backload
        AND NOT regexp_like(lower(i.key), '(^|/)backload/')
        -- Only known doc types
        AND (
            regexp_like(lower(i.key), '(^|/)ccd(/|$)')
            OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
            OR regexp_like(lower(i.key), '(^|/)oru(/|$)')
        )
)

SELECT
    date_format(md.month_start, '%Y-%m') AS month,
    date_format(md.target_day, '%Y-%m-%d') AS day,
    docs.qe,
    docs.data_type,
    count(*) AS doc_count
FROM docs
JOIN month_days md
    ON docs.dt = md.dt_target_partition
    AND docs.submission_date IS NOT NULL
    -- PDR data contributed before 2026-03-11 was only the HEADER information, not the clinical document; exclude it.
    AND docs.submission_date >= DATE '2026-03-11'
    AND docs.submission_date >= CAST(md.target_day AS timestamp)
    AND docs.submission_date < CAST(date_add('day', 1, md.target_day) AS timestamp)
GROUP BY 1, 2, 3, 4
ORDER BY qe ASC, data_type ASC, day ASC;
