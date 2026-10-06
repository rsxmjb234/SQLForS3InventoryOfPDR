/*
Expected cost/run: ~$2-3 (samples ~40 inventory days — every 5th day over 200)
Expected runtime: ~2-3 minutes

Goal:
- Trend the orphan problem over time: sample EVERY 5th DAY over the last 200
  days, counting the NUMBER OF DISTINCT ORPHAN SOURCES (assigning authorities)
  per QE on each sampled day. Enough points for a solid chart at ~1/5 the cost
  of a full day-by-day scan.
- An "orphan" is an assigning authority submitting CCD/TRN to the PDR that has
  NO matching entry in the Verato MPI (lookup_verato_aa).
- This is a COUNT OF SOURCES, not a document count. Example output:
    2026-09-01  bronx     ccd_orphan_sources=2   trn_orphan_sources=0
    2026-09-01  healthix  ccd_orphan_sources=24  trn_orphan_sources=12

Definitions (all are COUNTS OF DISTINCT SOURCES, not document counts):
- ccd_orphan_sources   = orphan AAs that submitted >=1 CCD that day
- trn_orphan_sources   = orphan AAs that submitted >=1 TRN that day
- total_orphan_sources = distinct orphan AAs active that day (CCD and/or TRN)
- total_ccd_sources    = ALL AAs (orphan or not) that submitted >=1 CCD that day
- total_trn_sources    = ALL AAs (orphan or not) that submitted >=1 TRN that day
- total_sources        = ALL distinct AAs active that day (CCD and/or TRN)

Rules (same AA-normalization as OrphanSourcesWithQENameFixed.sql):
- Verato AA suffixes .DUPLICATE / .DUPLICATE1 / .DUPLICATE2 / .DUPLICATE3 are
  stripped before comparing.
- For QE=BRONX only, underscores in Verato AA are treated as spaces.
- Excludes backlog; real-time only. Applies the 2026-03-11 clinical-data floor.
*/

WITH config AS (
    SELECT
        200 AS lookback_days,               -- << total span to cover
        5  AS sample_every_days,            -- << sample 1 day out of every N
        3  AS inventory_lag_days,
        2  AS inventory_snapshot_offset_days
),
date_range AS (
    SELECT
        date_add('day', -(c.lookback_days + c.inventory_lag_days - 1), current_date) AS start_day,
        date_add('day', -c.inventory_lag_days, current_date) AS end_day,
        c.sample_every_days,
        c.inventory_snapshot_offset_days
    FROM config c
),
-- Sample every Nth day across the span (step = sample_every_days)
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
        CAST(d.target_day AS timestamp) AS day_start_ts,
        CAST(date_add('day', 1, d.target_day) AS timestamp) AS day_end_ts,
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

-- Per day + QE + AA, did they submit any CCD / any TRN (real-time, no backlog)
pdr_daily AS (
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
        max(CASE WHEN regexp_like(lower(i.key), '(^|/)ccd(/|$)') THEN 1 ELSE 0 END) AS has_ccd,
        max(CASE WHEN regexp_like(lower(i.key), '(^|/)trn(/|$)') THEN 1 ELSE 0 END) AS has_trn
    FROM pdr_inventory.pdr_inventory_prod_data_all i
    JOIN params p
        ON i.dt = p.dt_target_partition
        AND i.last_modified_date >= p.day_start_ts
        AND i.last_modified_date < p.day_end_ts
    WHERE
        i.bucket LIKE 'nyec-pdr-prod-%'
        AND i.is_latest = true
        AND coalesce(i.is_delete_marker, false) = false
        -- PDR data contributed before 2026-03-11 was only the HEADER information, not the clinical document; exclude it.
        AND i.last_modified_date >= timestamp '2026-03-11 00:00:00'
        AND NOT regexp_like(lower(i.key), '(^|/)backload(/|$)')
        AND (
            regexp_like(lower(i.key), '(^|/)ccd(/|$)')
            OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
        )
    GROUP BY 1, 2, 3
),

-- Flag each day+QE+AA with whether it is an orphan (no matching Verato MPI entry)
flagged AS (
    SELECT
        d.day,
        d.qe,
        d.assigning_authority,
        d.has_ccd,
        d.has_trn,
        CASE WHEN v.assigning_authority IS NULL THEN 1 ELSE 0 END AS is_orphan
    FROM pdr_daily d
    LEFT JOIN qe_name_map m
        ON lower(d.qe) = lower(m.pdr_name)
    LEFT JOIN pdr_inventory.lookup_verato_aa v
        ON upper(v.qe) = upper(m.verato_name)
        AND upper(regexp_replace(regexp_replace(v.assigning_authority,
            '\.(DUPLICATE|DUPLICATE1|DUPLICATE2|DUPLICATE3)$', ''),
            CASE WHEN upper(m.verato_name) = 'BRONX' THEN '_' ELSE '' END,
            CASE WHEN upper(m.verato_name) = 'BRONX' THEN ' ' ELSE '' END
        )) = upper(d.assigning_authority)
    WHERE d.assigning_authority IS NOT NULL
      AND d.assigning_authority <> ''
)

SELECT
    date_format(day, '%Y-%m-%d') AS day,
    qe,
    -- Orphan source counts (no MPI entry)
    count_if(has_ccd = 1 AND is_orphan = 1) AS ccd_orphan_sources,
    count_if(has_trn = 1 AND is_orphan = 1) AS trn_orphan_sources,
    count_if(is_orphan = 1)                 AS total_orphan_sources,
    -- Total source counts contributing to PDR that day (orphan or not)
    count_if(has_ccd = 1) AS total_ccd_sources,
    count_if(has_trn = 1) AS total_trn_sources,
    count(*)              AS total_sources
FROM flagged
GROUP BY day, qe
ORDER BY day ASC, qe ASC;
