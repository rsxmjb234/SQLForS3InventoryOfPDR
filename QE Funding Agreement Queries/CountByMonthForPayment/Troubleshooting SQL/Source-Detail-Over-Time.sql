/*
Goal:
- Look at ONE source (assigning authority) in detail OVER TIME, so we can show a
  QE exactly what we are seeing. Starts with BRONX / MHHC.
- One row per month, with CCD, TRN, and Lab totals side by side, plus a grand
  total, so a decline (or shift between data types) is obvious at a glance.

Conventions (same as the monthly volume query of record):
- Reads ONE recent inventory snapshot (~1 partition scanned).
- Buckets by the TRUE submission date parsed from the key path
  (.../<type>/YYYY/Mon/DD/), NOT last_modified_date. last_modified gets
  re-stamped by metadata changes / bulk rewrites, which distorts "when was this
  submitted"; the key path preserves the real submission date. No anomaly-day
  exclusions are needed as a result.
- Excludes data before 2026-03-11 (header-only "bad date" rule).
- Excludes backload (real-time submissions only).
- QE = bucket name minus nyec-pdr-prod- prefix and -part2 suffix.
- Assigning authority = path segment 2 if first segment is processed/error/
  backload, else segment 1.
- Labs = 'lab' path segment (per rules.md), NOT 'oru'.

To reuse for another source: edit target_qe and target_aa below. Optionally
narrow the window with start_month / end_month.
*/

WITH config AS (
    SELECT
        'bronx' AS target_qe,                          -- << QE
        'MHHC'  AS target_aa,                           -- << source (assigning authority) to inspect
        DATE '2026-03-01' AS start_month,              -- << first month to show
        DATE '2026-10-01' AS end_month,                -- << last month to show
        date_format(date_add('day', -2, current_date), '%Y-%m-%d-01-00') AS single_snapshot_dt
),

typed AS (
    SELECT
        date_format(submission_date, '%Y-%m') AS month,
        data_type
    FROM (
        SELECT
            CASE
                WHEN regexp_like(lower(i.key), '(^|/)ccd(/|$)') THEN 'CCD'
                WHEN regexp_like(lower(i.key), '(^|/)trn(/|$)') THEN 'TRN'
                WHEN regexp_like(lower(i.key), '(^|/)lab(/|$)') THEN 'LAB'
            END AS data_type,
            -- True submission date parsed from the key path: <type>/YYYY/Mon/DD/
            TRY(date_parse(
                regexp_extract(i.key, '(?i)(?:ccd|trn|lab|oru)/(\d{4}/[A-Za-z]{3}/\d{2})/', 1),
                '%Y/%b/%d'
            )) AS submission_date
        FROM pdr_inventory.pdr_inventory_prod_data_all i
        CROSS JOIN config c
        WHERE
            i.dt = c.single_snapshot_dt
            AND i.bucket LIKE 'nyec-pdr-prod-%'
            AND regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '') = c.target_qe
            AND upper(trim(
                CASE
                    WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error', 'backload')
                    THEN split_part(i.key, '/', 2)
                    ELSE split_part(i.key, '/', 1)
                END
            )) = upper(c.target_aa)
            AND i.is_latest = true
            AND coalesce(i.is_delete_marker, false) = false
            -- Scan reducer only (re-stamps move dates forward; see rules.md).
            AND i.last_modified_date >= timestamp '2026-03-11 00:00:00'
            AND NOT regexp_like(lower(i.key), '(^|/)backload/')
            AND (
                regexp_like(lower(i.key), '(^|/)ccd(/|$)')
                OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
                OR regexp_like(lower(i.key), '(^|/)lab(/|$)')
            )
    ) t
    CROSS JOIN config c
    WHERE
        submission_date IS NOT NULL
        AND submission_date >= DATE '2026-03-11'
        AND submission_date >= c.start_month
        AND submission_date <  date_add('month', 1, c.end_month)
)

SELECT
    month,
    count_if(data_type = 'CCD') AS ccd_total,
    count_if(data_type = 'TRN') AS trn_total,
    count_if(data_type = 'LAB') AS lab_total,
    count(*) AS all_types_total
FROM typed
WHERE data_type IS NOT NULL
GROUP BY month
ORDER BY month ASC;
