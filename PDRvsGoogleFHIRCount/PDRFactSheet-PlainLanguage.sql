/*
Expected cost/run: ~$0.20 (two single-day snapshots, metadata columns only)
Expected runtime: ~1-2 minutes

Goal:
- Produce copy-paste-ready, plain-English facts about the PDR:
    1. Total documents in the PDR as of the most recent complete snapshot
       (CCD, TRN, labs via the /lab/ path segment) — excluding orphan sources and anything before
       2026-03-11.
    2. Typical daily intake (CCD, TRN, labs) = (today's total - 10-days-ago
       total) / 10.

Rules applied to BOTH counts:
- Excludes documents dated before 2026-03-11 (header-only period).
- Excludes backlog.
- Excludes "orphan" sources — AAs not present in the Verato MPI
  (lookup_verato_aa), using the same normalization as the ExcludeOrphans query:
    * strip Verato suffixes .DUPLICATE / .DUPLICATE1/2/3
    * for QE=BRONX, treat underscores as spaces
    * case-insensitive compare

Output: two one-row result sets, each a single ready-to-paste sentence.
Run both statements, or comment one out as needed.
*/

WITH config AS (
    SELECT
        4  AS recent_lag_days,              -- "today" = current_date - 4 (known-complete snapshot)
        10 AS avg_window_days,              -- daily average window
        2  AS inventory_snapshot_offset_days
),
anchors AS (
    SELECT
        date_add('day', -recent_lag_days, current_date)                      AS recent_day,
        date_add('day', -(recent_lag_days + avg_window_days), current_date)  AS older_day,
        avg_window_days,
        inventory_snapshot_offset_days
    FROM config
),
parts AS (
    SELECT
        recent_day,
        older_day,
        avg_window_days,
        date_format(date_add('day', inventory_snapshot_offset_days, recent_day), '%Y-%m-%d-01-00') AS recent_dt,
        date_format(date_add('day', inventory_snapshot_offset_days, older_day),  '%Y-%m-%d-01-00') AS older_dt
    FROM anchors
),

-- Map PDR bucket QE names to Verato QE names
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

-- Pre-normalize Verato AAs once (small) so the big join is plain equality
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

-- Pull both snapshots, classify type, derive QE + normalized AA
docs AS (
    SELECT
        CASE WHEN i.dt = p.recent_dt THEN 'recent' ELSE 'older' END AS which_snap,
        lower(regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '')) AS qe,
        upper(trim(
            CASE
                WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error', 'backload')
                THEN split_part(i.key, '/', 2)
                ELSE split_part(i.key, '/', 1)
            END
        )) AS aa_key,
        CASE
            WHEN regexp_like(lower(i.key), '(^|/)ccd(/|$)') THEN 'CCD'
            WHEN regexp_like(lower(i.key), '(^|/)trn(/|$)') THEN 'TRN'
            WHEN regexp_like(lower(i.key), '(^|/)lab(/|$)') THEN 'LAB'
        END AS data_type
    FROM pdr_inventory.pdr_inventory_prod_data_all i
    CROSS JOIN parts p
    WHERE i.dt IN (p.recent_dt, p.older_dt)
        AND i.bucket LIKE 'nyec-pdr-prod-%'
        AND i.is_latest = true
        AND coalesce(i.is_delete_marker, false) = false
        -- PDR data contributed before 2026-03-11 was only the HEADER information, not the clinical document; exclude it.
        AND i.last_modified_date >= timestamp '2026-03-11 00:00:00'
        AND NOT regexp_like(lower(i.key), '(^|/)backload(/|$)')
        AND (
            regexp_like(lower(i.key), '(^|/)ccd(/|$)')
            OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
            OR regexp_like(lower(i.key), '(^|/)lab(/|$)')
        )
),

-- Keep only sources that exist in Verato (exclude orphans)
kept AS (
    SELECT d.which_snap, d.data_type
    FROM docs d
    JOIN verato_norm vn
        ON d.qe = vn.pdr_qe
        AND d.aa_key = vn.aa_key
    WHERE d.data_type IS NOT NULL
),

counts AS (
    SELECT
        count_if(which_snap = 'recent' AND data_type = 'CCD') AS recent_ccd,
        count_if(which_snap = 'recent' AND data_type = 'TRN') AS recent_trn,
        count_if(which_snap = 'recent' AND data_type = 'LAB') AS recent_lab,
        count_if(which_snap = 'older'  AND data_type = 'CCD') AS older_ccd,
        count_if(which_snap = 'older'  AND data_type = 'TRN') AS older_trn,
        count_if(which_snap = 'older'  AND data_type = 'LAB') AS older_lab
    FROM kept
),

derived AS (
    SELECT
        recent_ccd, recent_trn, recent_lab,
        recent_ccd + recent_trn + recent_lab AS recent_total,
        CAST(round((recent_ccd - older_ccd) / CAST((SELECT avg_window_days FROM anchors) AS double)) AS bigint) AS ccd_per_day,
        CAST(round((recent_trn - older_trn) / CAST((SELECT avg_window_days FROM anchors) AS double)) AS bigint) AS trn_per_day,
        CAST(round((recent_lab - older_lab) / CAST((SELECT avg_window_days FROM anchors) AS double)) AS bigint) AS lab_per_day,
        (SELECT date_format(recent_day, '%m-%d-%Y') FROM anchors) AS as_of
    FROM counts
),

-- Format each number to a rounded short unit: >=1B -> "1.2B", >=1M -> "219M",
-- >=1K -> "450K", else the raw number. Done inline (Athena has no UDFs).
pretty AS (
    SELECT
        as_of,
        -- total
        CASE
            WHEN recent_total >= 1000000000 THEN format('%.1fB', recent_total / 1e9)
            WHEN recent_total >= 1000000    THEN format('%.0fM', recent_total / 1e6)
            WHEN recent_total >= 1000        THEN format('%.0fK', recent_total / 1e3)
            ELSE format('%,d', recent_total)
        END AS total_s,
        CASE
            WHEN recent_ccd >= 1000000000 THEN format('%.1fB', recent_ccd / 1e9)
            WHEN recent_ccd >= 1000000    THEN format('%.0fM', recent_ccd / 1e6)
            WHEN recent_ccd >= 1000        THEN format('%.0fK', recent_ccd / 1e3)
            ELSE format('%,d', recent_ccd)
        END AS ccd_s,
        CASE
            WHEN recent_trn >= 1000000000 THEN format('%.1fB', recent_trn / 1e9)
            WHEN recent_trn >= 1000000    THEN format('%.0fM', recent_trn / 1e6)
            WHEN recent_trn >= 1000        THEN format('%.0fK', recent_trn / 1e3)
            ELSE format('%,d', recent_trn)
        END AS trn_s,
        CASE
            WHEN recent_lab >= 1000000000 THEN format('%.1fB', recent_lab / 1e9)
            WHEN recent_lab >= 1000000    THEN format('%.0fM', recent_lab / 1e6)
            WHEN recent_lab >= 1000        THEN format('%.0fK', recent_lab / 1e3)
            ELSE format('%,d', recent_lab)
        END AS lab_s,
        -- per-day
        CASE
            WHEN ccd_per_day >= 1000000 THEN format('%.1fM', ccd_per_day / 1e6)
            WHEN ccd_per_day >= 1000    THEN format('%.0fK', ccd_per_day / 1e3)
            ELSE format('%,d', ccd_per_day)
        END AS ccd_day_s,
        CASE
            WHEN trn_per_day >= 1000000 THEN format('%.1fM', trn_per_day / 1e6)
            WHEN trn_per_day >= 1000    THEN format('%.0fK', trn_per_day / 1e3)
            ELSE format('%,d', trn_per_day)
        END AS trn_day_s,
        CASE
            WHEN lab_per_day >= 1000000 THEN format('%.1fM', lab_per_day / 1e6)
            WHEN lab_per_day >= 1000    THEN format('%.0fK', lab_per_day / 1e3)
            ELSE format('%,d', lab_per_day)
        END AS lab_day_s
    FROM derived
)

SELECT
    'As of ' || as_of || ' the PDR contained ' || chr(10)
      || total_s || ' documents made up of ' || chr(10)
      || ccd_s || ' CCDs' || chr(10)
      || trn_s || ' TRNs' || chr(10)
      || lab_s || ' labs' || chr(10)
      || 'Exclusions:' || chr(10)
      || 'Submitted after 2026-03-11 and excluding invalid (non-MPI) sources.'
    AS fact
FROM pretty

UNION ALL

SELECT
    'On a typical day the PDR receives' || chr(10)
      || ccd_day_s || ' CCDs' || chr(10)
      || trn_day_s || ' TRNs' || chr(10)
      || lab_day_s || ' labs' || chr(10)
      || 'Exclusions:' || chr(10)
      || 'Submitted after 2026-03-11 and excluding invalid (non-MPI) sources.'
    AS fact
FROM pretty;
