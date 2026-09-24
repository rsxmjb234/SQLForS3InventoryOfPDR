/*
Expected cost/run: ~$0.59 (118 GB scanned @ $5/TB for 10 days)
Expected runtime: ~1-2 minutes

Goal:
- Report ONLY on hospitals (via hospital_aa_reference).
- For the last 10 days, count CCDs and TRNs per hospital.
- Includes ALL hospital AAs — even those with zero data (shown as 0).
- Excludes backlog — only real-time submissions.
- Skips most recent 3 days for inventory freshness.

Matching note:
- hospital_aa_reference comes from a CSV (OpenCSVSerde) and its assigning
  authority values are matched to the inventory-derived AA using an
  UPPER(TRIM()) normalized key. The inventory AA is extracted from the S3
  key path (segment 1, or segment 2 when prefixed with processed/error).
*/

WITH config AS (
    SELECT
        10 AS lookback_days,                -- << 10-day window
        3  AS inventory_lag_days,           -- start 3 days ago (inventory lag)
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

-- Full deduplicated hospital list (master list — every row appears in output)
hospitals AS (
    SELECT
        upper(trim(assigning_authority)) AS assigning_authority_key,
        min(trim(assigning_authority)) AS assigning_authority,
        min(qe_name) AS qe_reference
    FROM pdr_inventory.hospital_aa_reference
    WHERE assigning_authority IS NOT NULL
      AND trim(assigning_authority) <> ''
    GROUP BY upper(trim(assigning_authority))
),

-- Actual counts from inventory (real-time only, no backlog)
actual AS (
    SELECT
        upper(trim(
            CASE
                WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error')
                THEN split_part(i.key, '/', 2)
                ELSE split_part(i.key, '/', 1)
            END
        )) AS assigning_authority_key,
        arbitrary(regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '')) AS qe,
        count_if(regexp_like(lower(i.key), '(^|/)ccd(/|$)')) AS ccd_count,
        count_if(regexp_like(lower(i.key), '(^|/)trn(/|$)')) AS trn_count
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
    GROUP BY 1
)

SELECT
    h.qe_reference AS qe,
    h.assigning_authority,
    coalesce(a.ccd_count, 0) AS ccd_count,
    coalesce(a.trn_count, 0) AS trn_count,
    coalesce(a.ccd_count, 0) + coalesce(a.trn_count, 0) AS total_docs
FROM hospitals h
LEFT JOIN actual a
    ON h.assigning_authority_key = a.assigning_authority_key
ORDER BY total_docs DESC, h.assigning_authority ASC;
