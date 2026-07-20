/*
Expected cost/run: ~$0.95 (194 GB scanned @ $5/TB for 20 days)
Expected runtime: ~2 minutes

Goal:
- Show daily TRN submission counts for ALL hospitals in the baseline table.
- Starts from lookup_stdev_average_for_hospitals to get the list of
  assigning authorities (hospitals), then counts TRNs from inventory.
- Includes ALL data paths and labels them: PROCESSED, ERROR, BACKLOG, or NORMAL.
- Handles key structures:
    processed/assigningAuthority/trn/...
    error/assigningAuthority/trn/...
    backload/assigningAuthority/trn/...
    assigningAuthority/trn/...
- Shows 0 for days with no submissions so gaps are visible.

How to use:
- Adjust lookback_days in config.
- Results are ordered by QE, assigning_authority, day, path_type.
- Good for charting TRN activity per hospital over time, broken out by path type.
*/

WITH config AS (
    SELECT
        40 AS lookback_days,                -- << CHANGE THIS
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

-- Deduplicated hospital list from baseline table
hospitals AS (
    SELECT
        upper(trim(assigning_authority)) AS assigning_authority_key,
        min(trim(assigning_authority)) AS assigning_authority,
        min(qe) AS qe
    FROM pdr_inventory.lookup_stdev_average_for_hospitals
    WHERE metric = 'TRN'
      AND assigning_authority IS NOT NULL
      AND trim(assigning_authority) <> ''
    GROUP BY upper(trim(assigning_authority))
),

-- Parse inventory: extract AA and classify path type
parsed_inventory AS (
    SELECT
        p.target_day AS day,

        upper(trim(
            CASE
                WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error', 'backload')
                THEN split_part(i.key, '/', 2)
                ELSE split_part(i.key, '/', 1)
            END
        )) AS assigning_authority_key,

        CASE
            WHEN lower(split_part(i.key, '/', 1)) = 'processed' THEN 'PROCESSED'
            WHEN lower(split_part(i.key, '/', 1)) = 'error'     THEN 'ERROR'
            WHEN regexp_like(lower(i.key), '(^|/)backload(/|$)') THEN 'BACKLOG'
            ELSE 'NORMAL'
        END AS path_type

    FROM pdr_inventory.pdr_inventory_prod_data_all i
    JOIN params p
        ON i.dt = p.dt_target_partition
        AND i.last_modified_date >= p.day_start_ts
        AND i.last_modified_date < p.day_end_ts
    WHERE
        i.bucket LIKE 'nyec-pdr-prod-%'
        AND i.is_latest = true
        AND coalesce(i.is_delete_marker, false) = false
        AND regexp_like(lower(i.key), '(^|/)trn(/|$)')
),

-- Aggregate by hospital, day, path_type
actual AS (
    SELECT
        pi.day,
        pi.assigning_authority_key,
        pi.path_type,
        count(*) AS trn_count
    FROM parsed_inventory pi
    INNER JOIN hospitals h
        ON pi.assigning_authority_key = h.assigning_authority_key
    WHERE pi.assigning_authority_key IS NOT NULL
      AND pi.assigning_authority_key <> ''
    GROUP BY 1, 2, 3
),

-- Every hospital × day × path_type combination so zeros show
path_types AS (
    SELECT path_type FROM (VALUES ('PROCESSED'), ('ERROR'), ('BACKLOG'), ('NORMAL')) AS t(path_type)
),
expected AS (
    SELECT
        d.target_day AS day,
        h.assigning_authority_key,
        h.assigning_authority,
        h.qe,
        pt.path_type
    FROM days d
    CROSS JOIN hospitals h
    CROSS JOIN path_types pt
)

SELECT
    e.qe,
    e.assigning_authority,
    date_format(e.day, '%Y-%m-%d') AS day,
    CASE
        WHEN day_of_week(e.day) IN (6, 7) THEN 'weekend'
        ELSE 'Weekday'
    END AS day_type,
    e.path_type,
    coalesce(a.trn_count, 0) AS trn_count
FROM expected e
LEFT JOIN actual a
    ON e.assigning_authority_key = a.assigning_authority_key
    AND e.day = a.day
    AND e.path_type = a.path_type
ORDER BY e.qe ASC, e.assigning_authority ASC, e.day ASC, e.path_type ASC;
