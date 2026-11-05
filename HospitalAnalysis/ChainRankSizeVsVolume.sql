/*
Goal:
- For each hospital CHAIN (assigning authority), compare its RANK by expected
  size against its RANK by actual submission volume, per data type.
- Idea: "MMC is the 10th largest chain by size, but the 99th largest CCD
  contributor" => big gap => worry.

How ranks read (rank 1 = biggest / most, so all ranks are comparable):
- size_rank : 1 = largest chain by summed scaler_size.
- ccd_rank / lab_rank / trn_rank : 1 = most docs of that type.
- *_gap = type_rank - size_rank.
    gap >> 0  => chain submits far LESS of this type than its size implies (WORRY)
    gap ~  0  => volume rank matches size rank (expected)
    gap <  0  => chain punches above its size for this type

KEY CONCEPT — chain-level sizing:
- Size is summed across all SHIN-NY facilities sharing one AA code
  (e.g. MMC = 1168+1169+1185+1305+3058 scaler sizes). S3 inventory is already
  keyed by AA, so doc counts roll up to the chain automatically.

Scope / rules:
- HOSPITALS ONLY. Last 10 days. 3-day inventory snapshot (lag = 3).
- Excludes PDR data before 2026-03-11 (header-only "bad date" rule).
- Doc types: CCD='ccd', Lab='lab' (per rules.md, NOT 'oru'), TRN='trn'.

Ranking notes:
- RANK() is used, so ties share a rank.
- Chains with 0 of a type still get ranked (they land at the bottom = largest rank).
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

-- Chain = AA code. Sum size across all FACILITIES sharing the code.
-- IMPORTANT hospital-roster filters (derived from the SFDC export):
--   * organization_type LIKE '%hospital%'  -> hospitals only
--   * code_level <> 'Sub-Facility'         -> drop Epic department sub-codes
--       (these are per-department CCD feeds, e.g. "RRH ... Epic Dept CCD";
--        including them inflated the chain count from ~185 to ~1,000)
--   * code_status = 'Active'               -> drop historical / deactivated codes
-- Net result: ~232 distinct hospital facilities across ~185 active AA codes.
-- Size is summed per FACILITY (distinct nys_facility_id), not per raw row, so a
-- facility that appears on several sub-rows is only counted once.
chains AS (
    SELECT
        assigning_authority_key,
        min(assigning_authority) AS assigning_authority,
        -- All distinct facility names for this chain, joined into one label.
        array_join(array_sort(array_agg(DISTINCT organization_name)), '; ') AS hospital_name,
        arbitrary(qe) AS qe,
        count(DISTINCT nys_facility_id) AS facility_count,
        sum(facility_size) AS chain_size
    FROM (
        -- One row per (AA code, facility): collapse multiple roster rows for the
        -- same facility under the same code, taking that facility's max size.
        SELECT
            upper(trim(code)) AS assigning_authority_key,
            trim(code) AS assigning_authority,
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
        GROUP BY upper(trim(code)), trim(code), nys_facility_id
    ) t
    GROUP BY assigning_authority_key
),

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
),

-- Join chains to their counts (0 where a chain submitted nothing).
joined AS (
    SELECT
        ch.qe,
        ch.assigning_authority AS chain_aa,
        ch.hospital_name,
        ch.facility_count,
        ch.chain_size,
        coalesce(c.ccd_count, 0) AS ccd_count,
        coalesce(c.lab_count, 0) AS lab_count,
        coalesce(c.trn_count, 0) AS trn_count
    FROM chains ch
    LEFT JOIN counts c
        ON ch.assigning_authority_key = c.assigning_authority_key
),

ranked AS (
    SELECT
        *,
        RANK() OVER (ORDER BY chain_size DESC) AS size_rank,
        RANK() OVER (ORDER BY ccd_count  DESC) AS ccd_rank,
        RANK() OVER (ORDER BY lab_count  DESC) AS lab_rank,
        RANK() OVER (ORDER BY trn_count  DESC) AS trn_rank
    FROM joined
)

SELECT
    qe,
    chain_aa,
    hospital_name,
    facility_count,
    chain_size,
    size_rank,
    ccd_count, ccd_rank, (ccd_rank - size_rank) AS ccd_gap,
    lab_count, lab_rank, (lab_rank - size_rank) AS lab_gap,
    trn_count, trn_rank, (trn_rank - size_rank) AS trn_gap,
    -- worst single underperformance across the three types (bigger = more worrying)
    greatest(
        (ccd_rank - size_rank),
        (lab_rank - size_rank),
        (trn_rank - size_rank)
    ) AS worst_gap
FROM ranked
ORDER BY worst_gap DESC, size_rank ASC;
