/*
Expected cost/run: ~$0.59 (118 GB scanned @ $5/TB for 10 days)
Expected runtime: ~1 minute

Goal:
- List every distinct assigning authority contributing ANY data to PDR
  in the last 10 days, with a document count and a sample S3 folder path.
- Use this to explore which sources exist and find 42 CFR paths manually.
- Skips most recent 3 days for inventory freshness.
- Includes all data types, all path types (no filters).

How to use:
- Run as-is to get the full list.
- Filter results in Excel for '42cfr' in the S3 path if needed.
- example part 2 s3://nyec-pdr-prod-healtheconnections-part2/processed/RRH-RRH/trn/2026/Aug/25/11

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
)

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
        WHEN i.bucket LIKE '%-part2' THEN 'Yes'
        ELSE 'No'
    END AS part2,
    count(*) AS doc_count,
    's3://' || max(i.bucket || '/' || substr(i.key, 1, length(i.key) - length(split_part(i.key, '/', cardinality(split(i.key, '/')))) - 1)) AS sample_s3_folder
FROM pdr_inventory.pdr_inventory_prod_data_all i
JOIN params p
    ON i.dt = p.dt_target_partition
    AND i.last_modified_date >= p.day_start_ts
    AND i.last_modified_date < p.day_end_ts
WHERE
    i.bucket LIKE 'nyec-pdr-prod-%'
    AND i.is_latest = true
    AND coalesce(i.is_delete_marker, false) = false
GROUP BY 1, 2, 3
ORDER BY qe ASC, part2 DESC, doc_count DESC;
