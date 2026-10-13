/*
Expected cost/run: ~$0.06 (single inventory day, ~12 GB @ $5/TB)
Expected runtime: ~30 seconds

Goal:
- We know the PDR receives labs (ORU) and possibly other document types, but
  our CCD/TRN classification misses them. This pulls a sample of documents that
  are NEITHER CCD NOR TRN so we can study the key path patterns and build a
  reliable ORU (lab) / other-type classifier.
- Looks at a single day (3 days ago, inventory-complete), excludes backlog.
- Returns up to 1,000 example keys plus the full S3 path and folder path.

How to use:
- Run, export, and eyeball the 'path' / 'key' columns to find the token that
  identifies labs (e.g. /oru/, /lab/, /mdm/, etc.).
- The path_tokens column lists the slash-separated segments to make patterns
  easy to spot.
*/

WITH config AS (
    SELECT
        3 AS inventory_lag_days,            -- single day = 3 days ago (complete)
        2 AS inventory_snapshot_offset_days
),
params AS (
    SELECT
        date_add('day', -c.inventory_lag_days, current_date) AS target_day,
        CAST(date_add('day', -c.inventory_lag_days, current_date) AS timestamp) AS day_start_ts,
        CAST(date_add('day', -(c.inventory_lag_days - 1), current_date) AS timestamp) AS day_end_ts,
        date_format(
            date_add('day', c.inventory_snapshot_offset_days,
                     date_add('day', -c.inventory_lag_days, current_date)),
            '%Y-%m-%d-01-00'
        ) AS dt_target_partition
    FROM config c
)

SELECT
    regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS qe,
    trim(
        CASE
            WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error', 'backload')
            THEN split_part(i.key, '/', 2)
            ELSE split_part(i.key, '/', 1)
        END
    ) AS assigning_authority,
    i.size,
    date_format(i.last_modified_date, '%Y-%m-%d %H:%i:%s') AS last_modified,
    -- Full folder path (key without the filename) for pattern-spotting
    substr(i.key, 1, length(i.key) - length(split_part(i.key, '/', cardinality(split(i.key, '/')))) - 1) AS folder_path,
    i.key,
    's3://' || i.bucket || '/' || i.key AS full_s3_path
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
    -- Everything that is NOT a CCD and NOT a TRN
    AND NOT regexp_like(lower(i.key), '(^|/)ccd(/|$)')
    AND NOT regexp_like(lower(i.key), '(^|/)trn(/|$)')
    -- Ignore folder-marker keys (keys that end in /)
    AND i.key NOT LIKE '%/'
LIMIT 1000;
