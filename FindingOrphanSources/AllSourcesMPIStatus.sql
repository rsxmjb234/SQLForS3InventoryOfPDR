/*
Expected cost/run: ~$0.59 (118 GB scanned @ $5/TB for 10 days)
Expected runtime: ~1 minute

Goal:
- List EVERY source (assigning authority) that has contributed any data to
  the PDR in the last 10 days.
- For each source, show whether it exists in the Verato MPI: IN_MPI or NOT_IN_MPI.
- Show CCD count and TRN count for the 10-day period.
- Includes all data (real-time, processed, error — excludes backlog).

Rules:
- Verato AA suffixes .DUPLICATE, .DUPLICATE1, .DUPLICATE2, .DUPLICATE3
  are stripped before comparing.
- For QE=BRONX: underscores in Verato AA are treated as spaces.
- All comparisons are case-insensitive.

QE name mapping (PDR bucket → Verato table):
    bronx              → BRONX
    rochester          → GRRHIO
    healtheconnections → HECDCS
    healthix           → HEALTHIX
    hixny              → HIXNY
    techbd             → TXD
    healthelink        → HEALTHELINK
*/

WITH config AS (
    SELECT
        10 AS lookback_days,                -- << CHANGE THIS
        3  AS inventory_lag_days,
        2  AS inventory_snapshot_offset_days
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

-- Get all sources from PDR inventory (excludes backlog)
pdr_sources AS (
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
        END AS data_type
    FROM pdr_inventory.pdr_inventory_prod_data_all i
    JOIN params p
        ON i.dt = p.dt_target_partition
        AND i.last_modified_date >= p.day_start_ts
        AND i.last_modified_date < p.day_end_ts
    WHERE
        i.bucket LIKE 'nyec-pdr-prod-%'
        AND i.is_latest = true
        AND coalesce(i.is_delete_marker, false) = false
        AND NOT regexp_like(lower(i.key), '(^|/)backload(/|$)')
        AND (
            regexp_like(lower(i.key), '(^|/)ccd(/|$)')
            OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
        )
),

-- Aggregate by QE + AA
pdr_summary AS (
    SELECT
        qe,
        assigning_authority,
        count_if(data_type = 'CCD') AS ccd_count,
        count_if(data_type = 'TRN') AS trn_count
    FROM pdr_sources
    WHERE assigning_authority IS NOT NULL
      AND assigning_authority <> ''
    GROUP BY 1, 2
),

-- Check MPI status
with_mpi_status AS (
    SELECT
        p.qe,
        p.assigning_authority,
        p.ccd_count,
        p.trn_count,
        CASE
            WHEN v.assigning_authority IS NOT NULL THEN 'IN_MPI'
            ELSE 'NOT_IN_MPI'
        END AS mpi_status
    FROM pdr_summary p
    LEFT JOIN qe_name_map m
        ON lower(p.qe) = lower(m.pdr_name)
    LEFT JOIN pdr_inventory.lookup_verato_aa v
        ON upper(v.qe) = upper(m.verato_name)
        AND upper(regexp_replace(regexp_replace(v.assigning_authority,
            '\.(DUPLICATE|DUPLICATE1|DUPLICATE2|DUPLICATE3)$', ''),
            CASE WHEN upper(m.verato_name) = 'BRONX' THEN '_' ELSE '' END,
            CASE WHEN upper(m.verato_name) = 'BRONX' THEN ' ' ELSE '' END
        )) = upper(p.assigning_authority)
)

SELECT
    qe,
    assigning_authority,
    mpi_status,
    ccd_count,
    trn_count,
    ccd_count + trn_count AS total_docs
FROM with_mpi_status
ORDER BY qe ASC, mpi_status ASC, total_docs DESC;
