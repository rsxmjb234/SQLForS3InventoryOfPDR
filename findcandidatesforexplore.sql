/*
Expected cost/run: ~$0.50 (single day partition, ~100 GB @ $5/TB)
Expected runtime: ~1 minute

Goal:
- Get a sample of up to 100 documents per assigning authority (source).
- Only real-time data (excludes backlog).
- Useful for exploring what each source is actually submitting —
  checking keys, sizes, doc types, etc.

How to use:
- Adjust the date in config if needed.
- Results give you up to 100 docs per source to inspect.
*/

WITH config AS (
    SELECT
        date_add('day', -3, current_date) AS target_day,    -- << 3 days ago to ensure inventory is complete
        2 AS inventory_snapshot_offset_days
),
params AS (
    SELECT
        c.target_day,
        CAST(c.target_day AS timestamp) AS day_start_ts,
        CAST(date_add('day', 1, c.target_day) AS timestamp) AS day_end_ts,
        date_format(
            date_add('day', c.inventory_snapshot_offset_days, c.target_day),
            '%Y-%m-%d-01-00'
        ) AS dt_target_partition
    FROM config c
),

ranked AS (
    SELECT
        CASE
            WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error', 'backload')
            THEN split_part(i.key, '/', 2)
            ELSE split_part(i.key, '/', 1)
        END AS assigning_authority,
        regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS qe,
        CASE
            WHEN regexp_like(lower(i.key), '(^|/)ccd(/|$)') THEN 'CCD'
            WHEN regexp_like(lower(i.key), '(^|/)trn(/|$)') THEN 'TRN'
            WHEN regexp_like(lower(i.key), '(^|/)oru(/|$)') THEN 'ORU'
        END AS data_type,
        i.key,
        i.size,
        i.last_modified_date,
        row_number() OVER (
            PARTITION BY
                CASE
                    WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error', 'backload')
                    THEN split_part(i.key, '/', 2)
                    ELSE split_part(i.key, '/', 1)
                END
            ORDER BY i.last_modified_date DESC
        ) AS rn
    FROM pdr_inventory.pdr_inventory_prod_data_all i
    JOIN params p
        ON i.dt = p.dt_target_partition
        AND i.last_modified_date >= p.day_start_ts
        AND i.last_modified_date < p.day_end_ts
    WHERE
        i.bucket LIKE 'nyec-pdr-prod-%'
        AND i.is_latest = true
        AND coalesce(i.is_delete_marker, false) = false
        -- Exclude backlog
        AND NOT regexp_like(lower(i.key), '(^|/)backload/')
        -- Only known doc types
        AND (
            regexp_like(lower(i.key), '(^|/)ccd(/|$)')
            OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
            OR regexp_like(lower(i.key), '(^|/)oru(/|$)')
        )
)

SELECT
    assigning_authority,
    qe,
    data_type,
    key,
    size,
    date_format(last_modified_date, '%Y-%m-%d %H:%i:%s') AS last_modified
FROM ranked
WHERE rn <= 100
ORDER BY assigning_authority ASC, data_type ASC, last_modified DESC;
