/*
Goal:
- Answer: "Are our LARGE hospitals submitting lots of data, and SMALL ones not much?"
- Scope: HOSPITALS ONLY (joined to lookup_hospital_assigning_authorities).
- Window: last 10 days of data.
- Inventory snapshot: 3-day-ago snapshot logic (inventory_lag_days = 3).
- Excludes PDR data before 2026-03-11 (header-only "bad date" rule, see rules.md).

About scaler_size:
- scaler_size is a NUMERIC size rank 1..10 (1 = smallest, 10 = largest).
  Some rows are blank (unknown size).
- We bucket it into bands for the summary:
      1-3   = small
      4-7   = medium
      8-10  = large
      blank = unknown
  Adjust the band CASE in `hospitals` if you want different cutoffs.

Design:
- SQL does the aggregation: per-hospital doc counts and bytes over 10 days,
  rolled up by size band. Output is small enough for an LLM to narrate the
  "do large = lots, small = little" story and flag outliers.

PART 1 (default): one row per size band.
PART 2: one row per hospital (uncomment at the bottom) for outlier hunting.
*/

WITH config AS (
    SELECT
        10 AS lookback_days,
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
    SELECT d AS target_day
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

-- Hospitals only, with numeric size rank + size band.
-- Dedupe on AA code; a code can appear on several facility rows, so take the
-- max defined scaler_size for that code (largest facility wins).
hospitals AS (
    SELECT
        assigning_authority_key,
        min(assigning_authority) AS assigning_authority,
        min(qe) AS qe,
        max(scaler_num) AS scaler_num,
        CASE
            WHEN max(scaler_num) IS NULL THEN 'unknown'
            WHEN max(scaler_num) BETWEEN 1 AND 3 THEN 'small'
            WHEN max(scaler_num) BETWEEN 4 AND 7 THEN 'medium'
            WHEN max(scaler_num) >= 8 THEN 'large'
            ELSE 'unknown'
        END AS size_band
    FROM (
        SELECT
            upper(trim(code)) AS assigning_authority_key,
            trim(code) AS assigning_authority,
            qe_name AS qe,
            TRY_CAST(nullif(trim(scaler_size), '') AS integer) AS scaler_num
        FROM lookup_hospital_assigning_authorities
        WHERE code IS NOT NULL
          AND trim(code) <> ''
          AND lower(organization_type) LIKE '%hospital%'
    ) t
    GROUP BY assigning_authority_key
),

tier_defined AS (
    SELECT size_band, count(*) AS hospitals_defined_in_band
    FROM hospitals
    GROUP BY size_band
),

-- Inventory rows for the window, AA extracted. Count all required data types
-- (CCD, TRN, labs) since the question is about total submission volume.
parsed_inventory AS (
    SELECT
        upper(trim(
            CASE
                WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error', 'backload')
                THEN split_part(i.key, '/', 2)
                ELSE split_part(i.key, '/', 1)
            END
        )) AS assigning_authority_key,
        CAST(i.size AS double) AS size_bytes
    FROM pdr_inventory.pdr_inventory_prod_data_all i
    JOIN params p
        ON i.dt = p.dt_target_partition
        AND i.last_modified_date >= p.day_start_ts
        AND i.last_modified_date < p.day_end_ts
    WHERE
        i.bucket LIKE 'nyec-pdr-prod-%'
        AND i.is_latest = true
        AND coalesce(i.is_delete_marker, false) = false
        -- 'bad date' rule: pre-2026-03-11 was header-only, not clinical docs.
        AND i.last_modified_date >= timestamp '2026-03-11 00:00:00'
        AND i.size IS NOT NULL
        AND (
            regexp_like(lower(i.key), '(^|/)ccd(/|$)')
            OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
            OR regexp_like(lower(i.key), '(^|/)lab(/|$)')
        )
),

per_hospital AS (
    SELECT
        h.qe,
        h.assigning_authority,
        h.scaler_num,
        h.size_band,
        count(*) AS docs_10d,
        sum(pi.size_bytes) AS bytes_10d
    FROM parsed_inventory pi
    INNER JOIN hospitals h
        ON pi.assigning_authority_key = h.assigning_authority_key
    GROUP BY h.qe, h.assigning_authority, h.scaler_num, h.size_band
),

band_summary AS (
    SELECT
        ph.size_band,
        count(*) AS hospitals_submitting,
        sum(ph.docs_10d) AS total_docs_10d,
        sum(ph.bytes_10d) AS total_bytes_10d,
        avg(ph.docs_10d) AS avg_docs_per_hospital,
        avg(ph.bytes_10d) AS avg_bytes_per_hospital
    FROM per_hospital ph
    GROUP BY ph.size_band
)

-- ===================== PART 1: size-band summary (default) =====================
SELECT
    bs.size_band,
    bs.hospitals_submitting,
    td.hospitals_defined_in_band,
    format('%,d', bs.total_docs_10d) AS total_docs_10d,
    round(bs.total_bytes_10d / pow(1024, 3), 2) AS total_gb_10d,
    format('%,d', CAST(round(bs.avg_docs_per_hospital, 0) AS bigint)) AS avg_docs_per_hospital_10d,
    round(bs.avg_bytes_per_hospital / pow(1024, 3), 3) AS avg_gb_per_hospital_10d,
    round((bs.total_bytes_10d / bs.total_docs_10d) / pow(1024, 2), 3) AS avg_doc_size_mb
FROM band_summary bs
LEFT JOIN tier_defined td
    ON bs.size_band = td.size_band
ORDER BY
    CASE bs.size_band
        WHEN 'large' THEN 1
        WHEN 'medium' THEN 2
        WHEN 'small' THEN 3
        ELSE 4
    END;
