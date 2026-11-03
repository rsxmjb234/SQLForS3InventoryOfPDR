/*
Funding Agreement Requirement:
"The total volume of data submitted is expected to remain consistent month to
month. For purposes of performance monitoring, each QE will be required to
submit, at a minimum the aggregate amount of data; NYeC will assess this using
a rolling two-month average of submitted volume, by data type, as the
'baseline.' Beginning June 15th (and monthly thereafter), NYeC will inform
each QE of its baseline. If, for a full calendar month, a QE's submitted
volume is more than 10% below its baseline, and the variance is not
attributable to expected changes (e.g., participant onboarding/offboarding or
other agreed-upon adjustments), the variance will be considered a PDR outage."

Goal:
- Monthly document count by QE and data type (CCD, TRN, ORU, LAB).
- Excludes backload data — only real-time/normal submissions.
- Shows BOTH:
    1. Raw monthly volume (doc_count)
    2. Rolling 2-month average baseline (rolling_2mo_avg)
- Also shows:
    - pct_of_baseline: current month as a % of the rolling baseline
    - below_10pct_flag: 'YES' if volume is more than 10% below baseline

How to use:
- Set start_month and end_month in config (first day of first/last month).
- start_month should be at least 2 months before the period you want to assess
  (so the rolling average has data to work from).
- Each row = one QE + data type + month.

SINGLE-SNAPSHOT APPROACH (fast / cheap):
- Reads ONE recent inventory snapshot partition (single_snapshot_dt) and buckets
  every object into its month by last_modified_date. PDR rarely rewrites the
  underlying objects, so one recent snapshot already contains the full history
  with correct last_modified_date values.
- This scans ~1 partition instead of ~1 partition per day, cutting cost ~100x.
- single_snapshot_dt defaults to yesterday's partition; set it to any recent,
  complete snapshot (format '%Y-%m-%d-01-00').

Expected cost/run: ~$0.50-1 total (single snapshot partition), regardless of the
number of months in the window.
*/

WITH config AS (
    SELECT
        DATE '2026-01-01' AS start_month,       -- << first day of first month (include 2+ months before assessment period)
        DATE '2026-09-01' AS end_month,         -- << first day of last month to include
        -- Single recent, complete snapshot partition to read from.
        date_format(date_add('day', -2, current_date), '%Y-%m-%d-01-00') AS single_snapshot_dt
),

-- Map PDR bucket QE names to Verato QE names (same mapping used by the orphan
-- queries in FindingOrphanSources).
qe_name_map AS (
    SELECT pdr_name, verato_name
    FROM (VALUES
        ('bronx',              'BRONX'),
        ('rochester',          'GRRHIO'),
        ('healtheconnections', 'HECDCS'),
        ('healthix',           'HEALTHIX'),
        ('hixny',              'HIXNY'),
        ('techbd',             'TXD'),
        ('healthelink',        'HEALTHELINK')
    ) AS t(pdr_name, verato_name)
),

-- Pre-normalize Verato AAs once (same normalization as the orphan queries:
-- strip .DUPLICATE* suffixes, and for BRONX treat underscores as spaces).
verato_norm AS (
    SELECT DISTINCT
        lower(m.pdr_name) AS pdr_qe,
        upper(
            CASE
                WHEN upper(m.verato_name) = 'BRONX'
                THEN replace(regexp_replace(v.assigning_authority,
                        '\.(DUPLICATE|DUPLICATE1|DUPLICATE2|DUPLICATE3)$', ''), '_', ' ')
                ELSE regexp_replace(v.assigning_authority,
                        '\.(DUPLICATE|DUPLICATE1|DUPLICATE2|DUPLICATE3)$', '')
            END
        ) AS aa_key
    FROM pdr_inventory.lookup_verato_aa v
    JOIN qe_name_map m
        ON upper(v.qe) = upper(m.verato_name)
),

-- PDR docs from ONE snapshot. The SUBMISSION DATE is parsed from the key path
-- (.../<type>/YYYY/Mon/DD/HH/...), NOT from last_modified_date. last_modified
-- gets re-stamped by bulk rewrites (e.g. the 2026-09-22 event), which falsely
-- inflated monthly counts; the key path preserves the true submission date and
-- never changes on rewrite, so no anomaly-day exclusions are needed.
pdr_docs AS (
    SELECT
        date_format(submission_date, '%Y-%m') AS month,
        date_trunc('month', submission_date) AS month_start,
        qe,
        assigning_authority,
        data_type
    FROM (
        SELECT
            regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS qe,
            upper(trim(
                CASE
                    WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error', 'backload')
                    THEN split_part(i.key, '/', 2)
                    ELSE split_part(i.key, '/', 1)
                END
            )) AS assigning_authority,
            CASE
                WHEN regexp_like(lower(i.key), '(^|/)ccd(/|$)') THEN 'CCD'
                WHEN regexp_like(lower(i.key), '(^|/)trn(/|$)') THEN 'TRN'
                WHEN regexp_like(lower(i.key), '(^|/)oru(/|$)') THEN 'ORU'
                -- Labs are identified by the 'lab' path segment (per rules.md), NOT 'oru'.
                WHEN regexp_like(lower(i.key), '(^|/)lab(/|$)') THEN 'LAB'
            END AS data_type,
            -- Submission date parsed from the key path: <type>/YYYY/Mon/DD/
            -- (?i) = case-insensitive match; keep the ORIGINAL casing (e.g. 'Aug')
            -- so date_parse's %b month-abbreviation works.
            TRY(date_parse(
                regexp_extract(i.key, '(?i)(?:ccd|trn|lab|oru)/(\d{4}/[A-Za-z]{3}/\d{2})/', 1),
                '%Y/%b/%d'
            )) AS submission_date
        FROM pdr_inventory.pdr_inventory_prod_data_all i
        CROSS JOIN config c
        WHERE
            i.dt = c.single_snapshot_dt
            AND i.bucket LIKE 'nyec-pdr-prod-%'
            AND i.is_latest = true
            AND coalesce(i.is_delete_marker, false) = false
            -- Scan reducer only: re-stamps move dates FORWARD, so any doc with a
            -- true submission >= 2026-03-11 also has last_modified >= 2026-03-11.
            -- This does not affect results, only reduces data scanned.
            AND i.last_modified_date >= timestamp '2026-03-11 00:00:00'
            -- Exclude backload
            AND NOT regexp_like(lower(i.key), '(^|/)backload/')
            -- Only known doc types
            AND (
                regexp_like(lower(i.key), '(^|/)ccd(/|$)')
                OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
                OR regexp_like(lower(i.key), '(^|/)oru(/|$)')
                OR regexp_like(lower(i.key), '(^|/)lab(/|$)')
            )
    ) t
    CROSS JOIN config c
    WHERE
        submission_date IS NOT NULL
        -- Clinical-data floor on the TRUE submission date (see rules.md).
        AND submission_date >= DATE '2026-03-11'
        -- Only objects submitted within the reporting window [start_month, end_month + 1 month).
        AND submission_date >= c.start_month
        AND submission_date <  date_add('month', 1, c.end_month)
),

-- Raw monthly counts: keep ONLY sources present in Verato (excludes orphans).
monthly_raw AS (
    SELECT
        d.month,
        d.month_start,
        d.qe,
        d.data_type,
        count(*) AS doc_count
    FROM pdr_docs d
    JOIN verato_norm vn
        ON lower(d.qe) = vn.pdr_qe
        AND d.assigning_authority = vn.aa_key
    WHERE d.data_type IS NOT NULL
    GROUP BY 1, 2, 3, 4
),

-- Add rolling 2-month average (baseline = average of prior 2 months)
with_baseline AS (
    SELECT
        month,
        qe,
        data_type,
        doc_count,
        CAST(round(avg(doc_count) OVER (
            PARTITION BY qe, data_type
            ORDER BY month_start
            ROWS BETWEEN 2 PRECEDING AND 1 PRECEDING
        )) AS bigint) AS rolling_2mo_avg
    FROM monthly_raw
)

SELECT
    month,
    qe,
    data_type,
    doc_count,
    rolling_2mo_avg,
    CASE
        WHEN rolling_2mo_avg IS NULL OR rolling_2mo_avg = 0 THEN NULL
        ELSE CAST(round(100.0 * doc_count / rolling_2mo_avg) AS bigint)
    END AS pct_of_baseline,
    CASE
        WHEN rolling_2mo_avg IS NULL OR rolling_2mo_avg = 0 THEN 'N/A'
        WHEN doc_count < (rolling_2mo_avg * 0.9) THEN 'YES'
        ELSE 'NO'
    END AS below_10pct_flag
FROM with_baseline
ORDER BY qe ASC, data_type ASC, month ASC;
