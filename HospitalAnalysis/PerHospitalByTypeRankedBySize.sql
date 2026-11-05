/*
Goal:
- One row PER HOSPITAL with CCD, Labs, and TRN broken out, so we can eyeball
  oddities / missing data (e.g. a large hospital with 0 labs).
- Ranked smallest -> largest by scaler_size (1 = smallest .. 10 = largest).
- Includes QE.

Scope / rules:
- HOSPITALS ONLY (joined to lookup_hospital_assigning_authorities).
- Last 10 days of data.
- 3-day-ago inventory snapshot logic (inventory_lag_days = 3).
- Excludes PDR data before 2026-03-11 (header-only "bad date" rule, see rules.md).

Notes:
- scaler_size is a numeric rank 1..10; blanks sort last.
- Same AA code can appear on multiple facility rows; we take max(scaler_size)
  per code (largest facility wins).
- Doc types: CCD = 'ccd', Labs = 'lab' (per rules.md, NOT 'oru'), TRN = 'trn'.
- Counts cover all path types (processed / error / backload / normal) since the
  goal is to spot oddities and missing data, not filter to a single path.
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

-- Hospitals only, deduped on AA code, with numeric size rank.
hospitals AS (
    SELECT
        assigning_authority_key,
        min(assigning_authority) AS assigning_authority,
        min(organization_name) AS organization_name,
        min(qe) AS qe,
        max(scaler_num) AS scaler_num
    FROM (
        SELECT
            upper(trim(code)) AS assigning_authority_key,
            trim(code) AS assigning_authority,
            organization_name,
            qe_name AS qe,
            TRY_CAST(nullif(trim(scaler_size), '') AS integer) AS scaler_num
        FROM lookup_hospital_assigning_authorities
        WHERE code IS NOT NULL
          AND trim(code) <> ''
          AND lower(organization_type) LIKE '%hospital%'
    ) t
    GROUP BY assigning_authority_key
),

-- Inventory rows for the window, AA extracted, typed as CCD / LAB / TRN.
parsed_inventory AS (
    SELECT
        upper(trim(
            CASE
                WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error', 'backload')
                THEN split_part(i.key, '/', 2)
                ELSE split_part(i.key, '/', 1)
            END
        )) AS assigning_authority_key,
        CASE
            WHEN regexp_like(lower(i.key), '(^|/)ccd(/|$)') THEN 'CCD'
            WHEN regexp_like(lower(i.key), '(^|/)lab(/|$)') THEN 'LAB'
            WHEN regexp_like(lower(i.key), '(^|/)trn(/|$)') THEN 'TRN'
        END AS doc_type
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
        -- GLOBAL RULE: exclude processed/ and error/ workflow-prefix objects
        -- (historical FHIR-processing copies; see rules.md). Dropped like the date rule.
        AND NOT regexp_like(lower(i.key), '^(processed|error)/')
        AND (
            regexp_like(lower(i.key), '(^|/)ccd(/|$)')
            OR regexp_like(lower(i.key), '(^|/)lab(/|$)')
            OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
        )
),

-- Count each doc type per hospital.
counts AS (
    SELECT
        pi.assigning_authority_key,
        count_if(pi.doc_type = 'CCD') AS ccd_count,
        count_if(pi.doc_type = 'LAB') AS lab_count,
        count_if(pi.doc_type = 'TRN') AS trn_count
    FROM parsed_inventory pi
    GROUP BY pi.assigning_authority_key
)

SELECT
    h.qe,
    h.assigning_authority,
    h.organization_name,
    h.scaler_num AS scaler_size,
    coalesce(c.ccd_count, 0) AS ccd_count,
    coalesce(c.lab_count, 0) AS lab_count,
    coalesce(c.trn_count, 0) AS trn_count,
    coalesce(c.ccd_count, 0) + coalesce(c.lab_count, 0) + coalesce(c.trn_count, 0) AS total_count
FROM hospitals h
LEFT JOIN counts c
    ON h.assigning_authority_key = c.assigning_authority_key
ORDER BY
    h.scaler_num ASC NULLS LAST,   -- smallest -> largest, unknown last
    total_count ASC,
    h.qe ASC,
    h.assigning_authority ASC;
