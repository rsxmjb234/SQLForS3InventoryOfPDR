/*
Goal:
- Look at ONE source (assigning authority) BY DAY, to pinpoint the exact day its
  volume dropped or went to zero. Starts with BRONX / MHHC, Oct 2026.
- One row per day, with CCD, TRN, and Lab totals side by side, plus a grand
  total, so a hard stop (e.g. "zero after Oct 12") is obvious.
- Days with NO submissions show as 0 across the board (gaps are visible), by
  generating every day in the window and left-joining the actual counts.

Conventions (same as the monthly volume / source-over-time queries):
- Reads ONE recent inventory snapshot (PDR rarely rewrites objects), bucketing
  by the TRUE submission date parsed from the key path
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

To reuse for another source/window: edit target_qe, target_aa, start_day, end_day.
*/

WITH config AS (
    SELECT
        'bronx'           AS target_qe,                -- << QE
        'MHHC'            AS target_aa,                 -- << source (assigning authority)
        -- Default window = last 90 days (ending 2 days ago, matching the snapshot).
        date_add('day', -91, current_date) AS start_day,   -- << first day to show
        date_add('day', -2,  current_date) AS end_day,     -- << last day to show
        date_format(date_add('day', -2, current_date), '%Y-%m-%d-01-00') AS single_snapshot_dt
),

-- Every calendar day in the window, so days with zero submissions still appear.
all_days AS (
    SELECT d AS day
    FROM config c
    CROSS JOIN UNNEST(sequence(c.start_day, c.end_day, INTERVAL '1' DAY)) AS t(d)
),

-- Actual submissions for this source, one row per doc, tagged by day + type.
-- Day comes from the TRUE submission date parsed from the key path.
typed AS (
    SELECT
        CAST(submission_date AS date) AS day,
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
        AND submission_date >= c.start_day
        AND submission_date <= c.end_day
),

daily AS (
    SELECT
        day,
        count_if(data_type = 'CCD') AS ccd_total,
        count_if(data_type = 'TRN') AS trn_total,
        count_if(data_type = 'LAB') AS lab_total
    FROM typed
    WHERE data_type IS NOT NULL
    GROUP BY day
)

SELECT
    date_format(d.day, '%Y-%m-%d') AS day,
    CASE WHEN day_of_week(d.day) IN (6, 7) THEN 'weekend' ELSE 'weekday' END AS day_type,
    coalesce(x.ccd_total, 0) AS ccd_total,
    coalesce(x.trn_total, 0) AS trn_total,
    coalesce(x.lab_total, 0) AS lab_total,
    coalesce(x.ccd_total, 0) + coalesce(x.trn_total, 0) + coalesce(x.lab_total, 0) AS all_types_total
FROM all_days d
LEFT JOIN daily x ON x.day = d.day
ORDER BY d.day ASC;
