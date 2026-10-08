/*
Expected cost/run: ~$2-3 (samples ~10 inventory days — every 10th day over 100)
Expected runtime: ~2-3 minutes

Goal:
- Count the CUMULATIVE TOTAL of PDR documents (CCD and TRN) by QE, as of each
  inventory snapshot, sampling every 10 days over the last 100 days.
- This is the TOTAL documents in the system on that snapshot date (full
  snapshot population), NOT documents added that day. The number should trend
  upward over time, not bounce day to day.
- EXCLUDE any document dated before 2026-03-12. PDR data contributed before
- That is when we fixed issue with headers being saved without docs.
  that date was only the HEADER information, not the clinical document, so it
  must not be counted (filtered via last_modified_date in the query body).
- EXCLUDE sources that are NOT in the Verato MPI. Those are the "orphan"
  sources listed in:
    FindingOrphanSources\2026-09-04-REPORT on All sources contributing to PDR not in Verato.csv
  They are excluded because they would be double-counted against the Google
  FHIR count.

Approach (equivalent to excluding that orphan list, but self-maintaining):
- Instead of hardcoding ~600 orphan AAs, we INNER JOIN each PDR source to the
  Verato MPI (lookup_verato_aa). Only sources that HAVE a Verato match are
  counted. Any source without a match (an orphan) is automatically excluded.
- Uses the same AA normalization as OrphanSourcesWithQENameFixed.sql:
    * strip Verato suffixes .DUPLICATE / .DUPLICATE1 / .DUPLICATE2 / .DUPLICATE3
    * for QE=BRONX, treat underscores in the Verato AA as spaces
    * case-insensitive compare

Output: date, qe, ccd, trn
*/

WITH config AS (
    SELECT
        100 AS lookback_days,               -- << total span to cover
        10  AS sample_every_days,           -- << sample 1 day out of every N
        3   AS inventory_lag_days,
        2   AS inventory_snapshot_offset_days
),
date_range AS (
    SELECT
        date_add('day', -(c.lookback_days + c.inventory_lag_days - 1), current_date) AS start_day,
        date_add('day', -c.inventory_lag_days, current_date) AS end_day,
        c.sample_every_days,
        c.inventory_snapshot_offset_days
    FROM config c
),
-- Sample every Nth day across the span
days AS (
    SELECT
        d AS target_day
    FROM date_range c
    CROSS JOIN UNNEST(
        sequence(c.start_day, c.end_day, INTERVAL '1' DAY * c.sample_every_days)
    ) AS t(d)
),
params AS (
    SELECT
        d.target_day,
        date_format(
            date_add('day', c.inventory_snapshot_offset_days, d.target_day),
            '%Y-%m-%d-01-00'
        ) AS dt_target_partition
    FROM days d
    CROSS JOIN date_range c
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

-- Pre-normalize Verato AAs ONCE (small table) so the big join is plain equality.
-- Produces a PDR-side QE name + normalized uppercase AA key per Verato row.
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

-- PDR documents per day + QE + AA + type (real-time only, no backlog)
pdr_docs AS (
    SELECT
        p.target_day AS day,
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
        END AS data_type
    FROM pdr_inventory.pdr_inventory_prod_data_all i
    JOIN params p
        ON i.dt = p.dt_target_partition
    WHERE
        i.bucket LIKE 'nyec-pdr-prod-%'
        AND i.is_latest = true
        AND coalesce(i.is_delete_marker, false) = false
        -- PDR data contributed before 2026-03-11 was only the HEADER information, not the clinical document; exclude it.
        AND i.last_modified_date >= timestamp '2026-03-12 00:00:00'
        AND NOT regexp_like(lower(i.key), '(^|/)backload(/|$)')
        AND (
            regexp_like(lower(i.key), '(^|/)ccd(/|$)')
            OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
        )
),

-- Keep ONLY sources that exist in Verato (excludes orphans / would-be double counts).
-- Plain-equality join on pre-normalized keys so Athena can hash-join efficiently.
in_verato AS (
    SELECT
        d.day,
        d.qe,
        d.data_type
    FROM pdr_docs d
    JOIN verato_norm vn
        ON lower(d.qe) = vn.pdr_qe
        AND d.assigning_authority = vn.aa_key
    WHERE d.data_type IS NOT NULL
)

SELECT
    date_format(day, '%Y-%m-%d') AS date,
    qe,
    count_if(data_type = 'CCD') AS ccd,
    count_if(data_type = 'TRN') AS trn
FROM in_verato
GROUP BY day, qe
ORDER BY day ASC, qe ASC;
