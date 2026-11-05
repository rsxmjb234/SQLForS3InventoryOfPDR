/*
Goal (per request):
- One row PER HOSPITAL FACILITY.
- Column 1: chain_name  — a best-GUESS human-readable chain name, derived from the
  facility names that share the chain's assigning authority (AA) code.
- Column 2: hospital_name — the individual facility name.
- Column 3: sparcs_rank — the CHAIN's rank by size (SPARCS-based scaler_size,
  summed across the chain's facilities). 1 = biggest chain .. ~180 = smallest.
- Then the CHAIN's rolled-up document volume (repeated on each facility row):
  CCD, TRN, ORU, LAB.

Definitions / decisions:
- A "chain" = all hospitals sharing the same assigning authority (AA) code.
  Since S3 inventory is keyed by AA, all facility volume rolls up to that one AA
  automatically ("attribute all data to the first/only AA in the chain").
- "SPARCS rank": the roster's scaler_size (1..10 size tier, SPARCS-derived) summed
  across the chain's facilities, then ranked DESC (1 = largest). There is no raw
  SPARCS discharge count in the roster, so scaler_size is the size proxy.
- TRN is the ADT-type document in this repo (see ChainRankSizeVsVolume_Definitions).
  ORU and LAB are shown separately: ORU = literal 'oru' path segment; LAB = 'lab'
  path segment (per rules.md labs live under 'lab', not 'oru').

Scope / rules (match the other HospitalAnalysis queries):
- HOSPITALS ONLY (lookup_hospital_assigning_authorities, organization_type like
  '%hospital%'), active codes, excluding Epic department sub-facility codes.
- Last 10 days; 3-day inventory snapshot lag.
- Excludes PDR data before 2026-03-11 (header-only "bad date" rule).
- Counts cover all path types (processed/error/backload/normal) to spot oddities.
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

-- One row per (AA code, facility): collapse duplicate roster rows for the same
-- facility, taking that facility's max size tier.
facility_level AS (
    SELECT
        upper(trim(code)) AS aa_key,
        nys_facility_id,
        min(trim(organization_name)) AS organization_name,
        arbitrary(qe_name) AS qe,
        max(coalesce(TRY_CAST(nullif(trim(scaler_size), '') AS integer), 0)) AS facility_size
    FROM lookup_hospital_assigning_authorities
    WHERE code IS NOT NULL
      AND trim(code) <> ''
      AND lower(organization_type) LIKE '%hospital%'
      AND lower(trim(coalesce(code_level, ''))) <> 'sub-facility'   -- drop Epic dept sub-codes
      AND lower(trim(coalesce(code_status, ''))) = 'active'         -- active codes only
    GROUP BY upper(trim(code)), nys_facility_id
),

-- Chain-level aggregates: size (summed), guessed chain name, member facilities.
-- The chain-name GUESS is the name of the chain's LARGEST facility (highest
-- scaler_size) — the flagship that usually gives the system its name
-- (e.g. MMC -> Montefiore Moses div; RGHS -> Rochester General). The AA code is
-- appended so the label is unambiguous. This is a heuristic, not an official
-- chain name.
chain_named AS (
    SELECT
        aa_key,
        arbitrary(qe) AS qe,
        count(DISTINCT nys_facility_id) AS facility_count,
        sum(facility_size) AS chain_size,
        -- max_by: organization_name of the facility with the greatest size.
        max_by(organization_name, facility_size) || ' (' || aa_key || ')' AS chain_name_guess
    FROM facility_level
    GROUP BY aa_key
),

-- Rank chains by size (SPARCS-based scaler_size summed). 1 = biggest.
chain_ranked AS (
    SELECT
        cn.*,
        RANK() OVER (ORDER BY cn.chain_size DESC) AS sparcs_rank
    FROM chain_named cn
),

-- Inventory rows for the window, AA extracted, typed.
parsed_inventory AS (
    SELECT
        upper(trim(
            CASE
                WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error', 'backload')
                THEN split_part(i.key, '/', 2)
                ELSE split_part(i.key, '/', 1)
            END
        )) AS aa_key,
        CASE
            WHEN regexp_like(lower(i.key), '(^|/)ccd(/|$)') THEN 'CCD'
            WHEN regexp_like(lower(i.key), '(^|/)trn(/|$)') THEN 'TRN'
            WHEN regexp_like(lower(i.key), '(^|/)oru(/|$)') THEN 'ORU'
            WHEN regexp_like(lower(i.key), '(^|/)lab(/|$)') THEN 'LAB'
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
        AND i.last_modified_date >= timestamp '2026-03-11 00:00:00'
        -- GLOBAL RULE: exclude processed/ and error/ workflow-prefix objects
        -- (historical FHIR-processing copies; see rules.md). Dropped like the date rule.
        AND NOT regexp_like(lower(i.key), '^(processed|error)/')
        AND (
            regexp_like(lower(i.key), '(^|/)ccd(/|$)')
            OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
            OR regexp_like(lower(i.key), '(^|/)oru(/|$)')
            OR regexp_like(lower(i.key), '(^|/)lab(/|$)')
        )
),

-- Chain-level doc counts (all facilities roll up to the one AA).
chain_counts AS (
    SELECT
        aa_key,
        count_if(doc_type = 'CCD') AS ccd_count,
        count_if(doc_type = 'TRN') AS trn_count,
        count_if(doc_type = 'ORU') AS oru_count,
        count_if(doc_type = 'LAB') AS lab_count
    FROM parsed_inventory
    GROUP BY aa_key
)

-- One row per facility, with the chain's name, SPARCS rank, and rolled-up volume.
SELECT
    cr.chain_name_guess                       AS chain_name,
    fl.organization_name                      AS hospital_name,
    cr.sparcs_rank,
    cr.aa_key                                 AS chain_aa,
    cr.qe,
    coalesce(cc.ccd_count, 0)                 AS chain_ccd,
    coalesce(cc.trn_count, 0)                 AS chain_trn,
    coalesce(cc.oru_count, 0)                 AS chain_oru,
    coalesce(cc.lab_count, 0)                 AS chain_lab
FROM chain_ranked cr
JOIN facility_level fl
    ON fl.aa_key = cr.aa_key
LEFT JOIN chain_counts cc
    ON cc.aa_key = cr.aa_key
ORDER BY
    cr.sparcs_rank ASC,
    cr.aa_key ASC,
    fl.organization_name ASC;
