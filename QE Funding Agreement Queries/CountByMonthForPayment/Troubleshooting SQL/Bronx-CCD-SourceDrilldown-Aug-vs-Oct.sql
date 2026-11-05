/*
Goal:
- Explore WHY a QE's volume dropped. Here: BRONX CCD volume is down ~20% from
  2026-08 to 2026-10, which is odd. This drills into the underlying CCD data by
  SOURCE (assigning authority) so we can see which sources drove the drop.

Output: one row per Bronx assigning authority, with CCD counts for each month
side by side, the absolute and % change, and whether the source matches Verato
(so you can tell if a dropped source is an orphan). Ranked from the biggest %
DROP to the biggest increase, so the causes of the decline sort to the top.

Conventions (same as the monthly volume query of record):
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
- NOTE: orphans are NOT excluded here. A source that dropped out may be an
  orphan; the verato_match column tells you which. (Set via LEFT JOIN.)

To reuse for another QE/months: edit target_qe, month_a, month_b below.
*/

WITH config AS (
    SELECT
        'bronx'          AS target_qe,                 -- << QE to investigate
        DATE '2026-08-01' AS month_a,                  -- << earlier (baseline) month
        DATE '2026-10-01' AS month_b,                  -- << later (dropped) month
        'CCD'            AS target_type,               -- << data type to drill into
        date_format(date_add('day', -2, current_date), '%Y-%m-%d-01-00') AS single_snapshot_dt
),

-- Verato normalization (same rules as the orphan queries), so we can flag
-- whether each Bronx source is in the MPI.
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

-- Bronx CCD docs from one snapshot, tagged to month A or month B by the TRUE
-- submission date parsed from the key path (not last_modified_date).
tagged AS (
    SELECT
        assigning_authority,
        CASE
            WHEN submission_date >= c.month_a
                 AND submission_date < date_add('month', 1, c.month_a)
            THEN 'A'
            WHEN submission_date >= c.month_b
                 AND submission_date < date_add('month', 1, c.month_b)
            THEN 'B'
        END AS which_month
    FROM (
        SELECT
            upper(trim(
                CASE
                    WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error', 'backload')
                    THEN split_part(i.key, '/', 2)
                    ELSE split_part(i.key, '/', 1)
                END
            )) AS assigning_authority,
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
            AND i.is_latest = true
            AND coalesce(i.is_delete_marker, false) = false
            -- Scan reducer only (re-stamps move dates forward; see rules.md).
            AND i.last_modified_date >= timestamp '2026-03-11 00:00:00'
            -- GLOBAL RULE: exclude processed/ and error/ workflow-prefix objects
            -- (historical FHIR-processing copies; see rules.md). Dropped like the date rule.
            AND NOT regexp_like(lower(i.key), '^(processed|error)/')
            AND NOT regexp_like(lower(i.key), '(^|/)backload/')
            AND regexp_like(lower(i.key), '(^|/)ccd(/|$)')
    ) t
    CROSS JOIN config c
    WHERE
        submission_date IS NOT NULL
        AND submission_date >= DATE '2026-03-11'
        AND (
            (submission_date >= c.month_a
             AND submission_date < date_add('month', 1, c.month_a))
            OR
            (submission_date >= c.month_b
             AND submission_date < date_add('month', 1, c.month_b))
        )
),

by_source AS (
    SELECT
        assigning_authority,
        count_if(which_month = 'A') AS ccd_month_a,
        count_if(which_month = 'B') AS ccd_month_b
    FROM tagged
    WHERE assigning_authority IS NOT NULL AND assigning_authority <> ''
    GROUP BY assigning_authority
)

SELECT
    s.assigning_authority,
    CASE WHEN vn.aa_key IS NOT NULL THEN 'in Verato' ELSE 'ORPHAN (not in Verato)' END AS verato_match,
    s.ccd_month_a,
    s.ccd_month_b,
    (s.ccd_month_b - s.ccd_month_a) AS change_abs,
    CASE
        WHEN s.ccd_month_a = 0 AND s.ccd_month_b = 0 THEN NULL
        WHEN s.ccd_month_a = 0 THEN NULL   -- new source: no baseline to % against
        ELSE CAST(round(100.0 * (s.ccd_month_b - s.ccd_month_a) / s.ccd_month_a) AS bigint)
    END AS pct_change,
    CASE
        WHEN s.ccd_month_a > 0 AND s.ccd_month_b = 0 THEN 'STOPPED (was submitting, now zero)'
        WHEN s.ccd_month_a = 0 AND s.ccd_month_b > 0 THEN 'NEW (none before, submitting now)'
        WHEN s.ccd_month_b < s.ccd_month_a THEN 'DOWN'
        WHEN s.ccd_month_b > s.ccd_month_a THEN 'UP'
        ELSE 'FLAT'
    END AS status
FROM by_source s
LEFT JOIN verato_norm vn
    ON vn.pdr_qe = (SELECT lower(target_qe) FROM config)
    AND s.assigning_authority = vn.aa_key
ORDER BY
    -- Biggest percentage DROP first; sources that STOPPED sort to the very top.
    CASE WHEN s.ccd_month_a > 0 AND s.ccd_month_b = 0 THEN 0 ELSE 1 END ASC,
    (CASE
        WHEN s.ccd_month_a = 0 THEN 999999
        ELSE 100.0 * (s.ccd_month_b - s.ccd_month_a) / s.ccd_month_a
     END) ASC,
    s.ccd_month_a DESC;
