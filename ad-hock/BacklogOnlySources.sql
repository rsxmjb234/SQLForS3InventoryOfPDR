/*
Expected cost/run: ~$0.95 (194 GB scanned @ $5/TB for 20 days)
Expected runtime: ~2 minutes

Goal:
- Identify hospital sources that submit data ONLY via backlog (no real-time).
- These sources will baseline at 0 in real-time variance detection, so we need
  to know who they are and handle them differently.
- Also shows total backlog doc count by data type so you can see their volume.
- Looks back 20 days, excludes last 3 days for inventory lag.

How to use:
- Run as-is to get the list.
- Sources that appear here should NOT be flagged as "outage" in real-time
  variance detection — they never submitted real-time to begin with.
*/

WITH config AS (
    SELECT
        5  AS lookback_days,                -- << CHANGE THIS
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

-- All hospital activity, tagged by path type
all_activity AS (
    SELECT
        CASE
            WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error', 'backload')
            THEN split_part(i.key, '/', 2)
            ELSE split_part(i.key, '/', 1)
        END AS assigning_authority,
        regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS qe,
        CASE
            WHEN regexp_like(lower(i.key), '(^|/)backload/') THEN 'BACKLOG'
            ELSE 'REALTIME'
        END AS path_type,
        CASE
            WHEN regexp_like(lower(i.key), '(^|/)ccd(/|$)') THEN 'CCD'
            WHEN regexp_like(lower(i.key), '(^|/)trn(/|$)') THEN 'TRN'
            WHEN regexp_like(lower(i.key), '(^|/)oru(/|$)') THEN 'ORU'
        END AS data_type
    FROM pdr_inventory.pdr_inventory_prod_data_all i
    JOIN params p
        ON i.dt = p.dt_target_partition
        AND i.last_modified_date >= p.day_start_ts
        AND i.last_modified_date < p.day_end_ts
    INNER JOIN pdr_inventory.hospital_aa_reference h
        ON upper(
            CASE
                WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error', 'backload')
                THEN split_part(i.key, '/', 2)
                ELSE split_part(i.key, '/', 1)
            END
        ) = upper(h.assigning_authority)
    WHERE
        i.bucket LIKE 'nyec-pdr-prod-%'
        AND i.is_latest = true
        AND coalesce(i.is_delete_marker, false) = false
        AND (
            regexp_like(lower(i.key), '(^|/)ccd(/|$)')
            OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
            OR regexp_like(lower(i.key), '(^|/)oru(/|$)')
        )
),

-- Sources that have backlog but NO real-time
backlog_sources AS (
    SELECT DISTINCT assigning_authority
    FROM all_activity
    WHERE path_type = 'BACKLOG'
),
realtime_sources AS (
    SELECT DISTINCT assigning_authority
    FROM all_activity
    WHERE path_type = 'REALTIME'
),
backlog_only AS (
    SELECT assigning_authority
    FROM backlog_sources
    WHERE assigning_authority NOT IN (SELECT assigning_authority FROM realtime_sources)
)

SELECT
    a.assigning_authority,
    a.qe,
    a.data_type,
    count(*) AS backlog_doc_count
FROM all_activity a
INNER JOIN backlog_only bo
    ON a.assigning_authority = bo.assigning_authority
WHERE a.path_type = 'BACKLOG'
  AND a.data_type IS NOT NULL
GROUP BY 1, 2, 3
ORDER BY qe ASC, assigning_authority ASC, data_type ASC;
