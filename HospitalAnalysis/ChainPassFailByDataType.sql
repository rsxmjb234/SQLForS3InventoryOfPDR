/*
Goal:
- One row PER HOSPITAL CHAIN (assigning authority), smallest -> largest by size.
- Show total CCD, total Lab, total TRN over the last 10 days.
- Give a PASS / FAIL per data type so oddities / missing data jump out.

KEY CONCEPT — chain-level sizing:
- Size is summed across all SHIN-NY facilities that share one AA code.
  Example: AA 'MMC' = facilities FS000001168 (8), FS000001169 (10),
  FS000001185 (blank), FS000001305 (10), FS000003058 (9)  => chain size = 37.
- S3 inventory is already keyed by AA, so doc counts naturally roll up to the
  chain. Summing facility sizes gives the matching "expected size" concept.

Scope / rules:
- HOSPITALS ONLY (lookup_hospital_assigning_authorities, organization_type LIKE '%hospital%').
- Last 10 days of data.
- 3-day-ago inventory snapshot logic (inventory_lag_days = 3).
- Excludes PDR data before 2026-03-11 (header-only "bad date" rule, see rules.md).
- Doc types: CCD='ccd', Lab='lab' (per rules.md, NOT 'oru'), TRN='trn'.

PASS / FAIL RULE  (<<< TUNE HERE >>>):
- There is no stored "expected volume per size" baseline, so Pass/Fail here is a
  PRESENCE check: a chain is expected to submit each required data type over 10 days.
      FAIL = submitted fewer than the per-type minimum below
      PASS = met or exceeded it
- Minimums are set to 1 (i.e. FAIL only when a type is completely missing).
  Raise these if you want "too little for its size" to also fail.
*/

WITH config AS (
    SELECT
        10 AS lookback_days,
        3  AS inventory_lag_days,
        2  AS inventory_snapshot_offset_days,
        -- <<< TUNE PASS/FAIL MINIMUMS (docs over the 10-day window) >>>
        1  AS min_ccd,
        1  AS min_lab,
        1  AS min_trn
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

-- Chain = AA code. Sum size across all facilities sharing the code.
-- QE: take the most common QE label for the code (codes map to one QE in practice).
chains AS (
    SELECT
        assigning_authority_key,
        min(assigning_authority) AS assigning_authority,
        arbitrary(qe) AS qe,
        count(*) AS facility_count,
        sum(scaler_num) AS chain_size,   -- summed facility sizes (blanks counted as 0)
        max(scaler_num) AS max_facility_size
    FROM (
        SELECT
            upper(trim(code)) AS assigning_authority_key,
            trim(code) AS assigning_authority,
            qe_name AS qe,
            coalesce(TRY_CAST(nullif(trim(scaler_size), '') AS integer), 0) AS scaler_num
        FROM lookup_hospital_assigning_authorities
        WHERE code IS NOT NULL
          AND trim(code) <> ''
          AND lower(organization_type) LIKE '%hospital%'
    ) t
    GROUP BY assigning_authority_key
),

-- Inventory for the window, AA extracted, typed.
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

counts AS (
    SELECT
        assigning_authority_key,
        count_if(doc_type = 'CCD') AS ccd_count,
        count_if(doc_type = 'LAB') AS lab_count,
        count_if(doc_type = 'TRN') AS trn_count
    FROM parsed_inventory
    GROUP BY assigning_authority_key
)

SELECT
    ch.qe,
    ch.assigning_authority AS chain_aa,
    ch.facility_count,
    ch.chain_size,
    coalesce(c.ccd_count, 0) AS total_ccd,
    coalesce(c.lab_count, 0) AS total_lab,
    coalesce(c.trn_count, 0) AS total_trn,
    CASE WHEN coalesce(c.ccd_count, 0) >= cfg.min_ccd THEN 'PASS' ELSE 'FAIL' END AS ccd_status,
    CASE WHEN coalesce(c.lab_count, 0) >= cfg.min_lab THEN 'PASS' ELSE 'FAIL' END AS lab_status,
    CASE WHEN coalesce(c.trn_count, 0) >= cfg.min_trn THEN 'PASS' ELSE 'FAIL' END AS trn_status
FROM chains ch
CROSS JOIN config cfg
LEFT JOIN counts c
    ON ch.assigning_authority_key = c.assigning_authority_key
ORDER BY
    ch.chain_size ASC,              -- smallest chain -> largest
    ch.assigning_authority ASC;
