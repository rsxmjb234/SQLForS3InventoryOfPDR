/*
Expected cost/run: ~$0.59 (118 GB scanned @ $5/TB for 10 days)
Expected runtime: ~1 minute

Goal:
- Find all QE|Assigning Authority combinations that are actively contributing
  CCDs to the PDR but are NOT yet classified in the EHR software analysis
  (pdr_inventory.ehr_software_analysis table).
- This ensures every organization sending CCDs gets analyzed — we want full
  coverage in the EPIC classification report.
- We only care about distinct organizations, not individual CCD documents.

How it works:
1. Pulls 10 days of CCD inventory data (excludes backlog).
2. Builds QE|AA keys from inventory.
3. Builds QE|AA keys from the ehr_software_analysis table (deriving QE from
   the S3 path in the 'path' column).
4. LEFT JOINs — any inventory source with no match in the analysis is a gap.
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

-- All QE|AA combinations contributing CCDs to PDR (last 10 days) with counts
pdr_ccd_sources AS (
    SELECT
        regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS qe,
        upper(trim(
            CASE
                WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error', 'backload')
                THEN split_part(i.key, '/', 2)
                ELSE split_part(i.key, '/', 1)
            END
        )) AS assigning_authority,
        count(*) AS ccd_count
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
        AND regexp_like(lower(i.key), '(^|/)ccd(/|$)')
    GROUP BY 1, 2
    HAVING count(*) >= 20
),

-- Distinct AA combinations already analyzed in ehr_software_analysis
-- Extract QE from bucket name in path, extract AA from path segments
analyzed_sources AS (
    SELECT DISTINCT
        upper(trim(
            regexp_replace(
                regexp_extract(path, 'nyec-pdr-prod-([^/]+)', 1),
                '-part2$', ''
            )
        )) AS qe,
        -- Extract AA from path: after bucket, first segment (or second if processed/error/backload)
        upper(trim(
            CASE
                WHEN lower(split_part(regexp_extract(path, 'nyec-pdr-prod-[^/]+/(.+)', 1), '/', 1))
                     IN ('processed', 'error', 'backload')
                THEN split_part(regexp_extract(path, 'nyec-pdr-prod-[^/]+/(.+)', 1), '/', 2)
                ELSE split_part(regexp_extract(path, 'nyec-pdr-prod-[^/]+/(.+)', 1), '/', 1)
            END
        )) AS assigning_authority,
        ehr_guess
    FROM pdr_inventory.ehr_software_analysis
    WHERE path IS NOT NULL
      AND path <> ''
)

-- Every source with analysis status
SELECT
    p.qe,
    p.assigning_authority,
    p.ccd_count,
    CASE
        WHEN a.assigning_authority IS NOT NULL THEN 'Yes'
        ELSE 'No'
    END AS in_ehr_analysis,
    a.ehr_guess
FROM pdr_ccd_sources p
LEFT JOIN analyzed_sources a
    ON upper(p.qe) = a.qe
    AND upper(p.assigning_authority) = a.assigning_authority
WHERE p.assigning_authority IS NOT NULL
  AND p.assigning_authority <> ''
ORDER BY p.qe ASC, p.ccd_count DESC;
