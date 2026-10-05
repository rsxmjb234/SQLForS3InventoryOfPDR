/*
Expected cost/run: ~$0.59 (118 GB scanned @ $5/TB for 10 days)
Expected runtime: ~1-2 minutes

Goal:
- Report ONLY on hospitals, for the last 10 days, counting CCDs and TRNs per
  assigning authority (code). QE is NOT considered — we work purely at the
  assigning-authority level.
- Includes ALL hospital AAs — even those with zero data (shown as 0).
- Excludes backlog — only real-time submissions.
- Skips most recent 3 days for inventory freshness.

Hospital definition (from lookup_hospital_assigning_authorities):
- record_type       = 'Assigning Authority'
- organization_type = 'Article 28 - Hospital'
- code              = the assigning authority used to match the S3 inventory path

Matching note:
- The hospital 'code' is matched to the inventory-derived AA using an
  UPPER(TRIM()) normalized key. The inventory AA is extracted from the S3 key
  path (segment 1, or segment 2 when prefixed with processed/error).
- Matching is on the AA code only, regardless of which QE bucket the data
  landed in.
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

-- Full deduplicated hospital AA list (master list — every AA appears in output)
hospitals AS (
    SELECT
        upper(trim(code)) AS assigning_authority_key,
        min(trim(code)) AS assigning_authority,
        min(trim(organization_name)) AS organization_name
    FROM pdr_inventory.lookup_hospital_assigning_authorities
    WHERE record_type = 'Assigning Authority'
      AND organization_type = 'Article 28 - Hospital'
      AND code IS NOT NULL
      AND trim(code) <> ''
    GROUP BY upper(trim(code))
),

-- Actual counts from inventory (real-time only, no backlog), keyed by AA only
actual AS (
    SELECT
        upper(trim(
            CASE
                WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error')
                THEN split_part(i.key, '/', 2)
                ELSE split_part(i.key, '/', 1)
            END
        )) AS assigning_authority_key,
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
        -- PDR data contributed before 2026-03-11 was only the HEADER information, not the clinical document; exclude it.
        AND i.last_modified_date >= timestamp '2026-03-11 00:00:00'
        AND NOT regexp_like(lower(i.key), '(^|/)backload(/|$)')
        AND (
            regexp_like(lower(i.key), '(^|/)ccd(/|$)')
            OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
        )
    GROUP BY 1
)

SELECT
    h.assigning_authority,
    h.organization_name,
    coalesce(a.ccd_count, 0) AS ccd_count,
    coalesce(a.trn_count, 0) AS trn_count,
    coalesce(a.ccd_count, 0) + coalesce(a.trn_count, 0) AS total_docs
FROM hospitals h
LEFT JOIN actual a
    ON h.assigning_authority_key = a.assigning_authority_key
ORDER BY total_docs DESC, h.assigning_authority ASC;
