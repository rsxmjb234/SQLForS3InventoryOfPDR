/*
Expected cost/run: ~$0.45 (ONE inventory snapshot; Athena reads it twice, ~93 GB)
Expected runtime: ~1-2 minutes

ANNUALIZING (directionally accurate, not exact)
- PDR never deletes data, so any recent inventory snapshot holds everything. We
  read ONE snapshot from about a week ago, count 28 complete days of documents,
  and project a year:  annual = (28-day count / 28) * 365.
- Use the *_annual columns for annual projections; the *_28d columns are the
  raw counts they come from.

MACRO QUESTION
- Are the BIG hospital systems (by SPARCS size) the BIG contributors of CCD, LAB
  and TRN, and the small systems small? Which systems send each document type,
  and which send none?
- ADT will be added as another volume column once it is loaded.

THE KEY: ASSIGNING AUTHORITY (AA)
- An AA is, at its core, an EPIC instance. Everything that instance sends reaches
  PDR under one AA, so the AA is what binds the data together.
- One AA commonly serves SEVERAL hospitals (e.g. a health system running three
  hospitals on one EPIC instance sends everything under a single AA).
- SPARCS counts those hospitals SEPARATELY (to SPARCS they are three hospitals),
  but PDR volume cannot be split by hospital - it only arrives per AA.
- So the comparison is made at the AA level:
      SUM of SPARCS size across the AA's hospitals   vs   the AA's document volume.
- A "system" (chain) here = one AA. It can be a single hospital.

WHICH HOSPITALS ARE IN THE REPORT (~194 distinct, each listed ONCE)
- The SFDC roster holds more than hospitals: imaging centers, "extension
  clinics", off-campus EDs and campus/division records. A real hospital is one
  that SPARCS knows, so a hospital is kept ONLY if the roster carries a SPARCS
  size (scaler_size > 0) for its NYS Facility ID. Everything else is dropped.
- A hospital can be listed under more than one AA on the roster (24 are). To
  count each hospital once - in SPARCS totals and in the row count - it is
  assigned to ONE AA: the listed AA with the most document volume in the window
  (ties and silent AAs -> alphabetically first). roster_aas_listed shows every
  AA the roster lists for it, so nothing is hidden.

SHAPE
- One row per hospital, grouped by QE, then by system (AA): QE -> system -> who
  the participants are. System-level values repeat on each participant row; use
  count_chain_once = 1 to sum them in Excel without double counting.

COLUMNS
- qe (roster QE for the AA; "a/b" if the roster lists it under two QEs),
  chain_name (guess = the system's largest hospital + AA), chain_aa,
  hospital_name, nys_facility_id, roster_aas_listed
- sends_ccd, sends_trn, sends_lab, sends_oru (Y/N: does the system send that
  type at all in the 28-day window)
- hospital_sparcs_size (scaler_size, 1 = smallest .. 10 = largest tier) and
  hospital_size_tier
- chain_hospital_count, chain_sparcs_sum and chain_size_tier
- SIZE TIERS (simple 3-way grouping of the SPARCS size): 01-Small = 1 to 3,
  02-Medium = 4 to 7, 03-Large = 8 to 10. The same cutoffs are applied to a
  system's SUMMED size, so a one-hospital system gets the same tier as its
  hospital and a multi-hospital system moves up as its hospitals add up. The
  numeric sizes stay in the file because the sums and ranks are built from them.
- size_rank_overall (1 = biggest system), size_rank_in_qe
- chain_ccd, chain_trn, chain_lab, chain_oru  (raw counts, 28 complete days)
- annual_ccd, annual_trn, annual_lab, annual_oru  (= count / 28 * 365)
- volume_bucket_qes: the PDR bucket(s) the volume actually lands in
- ccd_rank, trn_rank, lab_rank (1 = most volume) and *_gap = volume rank - size
  rank. A big positive gap = a big system sending little of that type (worry).
- annual_ccd_per_sparcs_point = annual_ccd / chain_sparcs_sum

RULES APPLIED (see rules.md)
- ROSTER: lookup_hospital_assigning_authorities, hospitals only, organization
  active, participating = 1, code active, Epic department sub-facility codes
  dropped, SPARCS size present.
- VOLUME: one snapshot from 7 days ago; submission date parsed from the S3 key
  path (not last_modified_date); 28 complete days ending the day before the
  snapshot (the snapshot-edge day is partial). Data before 2026-03-12 excluded.
  Backload and the processed/ and error/ prefixes excluded.
- Volume is matched on AA only, summed across all PDR buckets. A hospital's
  roster QE is not always the bucket its documents land in.
*/

WITH config AS (
    SELECT
        date_format(date_add('day', -7, current_date), '%Y-%m-%d-01-00') AS single_snapshot_dt,
        date_add('day', -(7 + 28), current_date) AS window_start,
        date_add('day', -7, current_date)        AS window_end_exclusive,
        28 AS window_days
),

-- Roster QE name -> short QE name.
qe_map AS (
    SELECT roster_qe, qe_short
    FROM (VALUES
        ('Bronx RHIO',         'bronx'),
        ('HEALTHeLINK',        'healthelink'),
        ('HealtheConnections', 'healtheconnections'),
        ('Healthix',           'healthix'),
        ('Hixny',              'hixny'),
        ('Rochester RHIO',     'rochester')
    ) AS t(roster_qe, qe_short)
),

-- Volume from ONE snapshot, dated by the key-path submission date.
key_parts AS (
    SELECT
        regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS bucket_qe,
        upper(trim(split_part(i.key, '/', 1))) AS aa,
        lower(split_part(i.key, '/', 2)) AS doc_seg,
        TRY(date_parse(
            regexp_extract(i.key, '(?i)(?:ccd|trn|lab|oru)/(\d{4}/[A-Za-z]{3}/\d{2})/', 1),
            '%Y/%b/%d'
        )) AS submission_date
    FROM pdr_inventory.pdr_inventory_prod_data_all i
    CROSS JOIN config c
    WHERE i.dt = c.single_snapshot_dt
      AND i.bucket LIKE 'nyec-pdr-prod-%'
      AND i.is_latest = true
      AND coalesce(i.is_delete_marker, false) = false
      -- Scan reducer / header-only floor.
      AND i.last_modified_date >= timestamp '2026-03-12 00:00:00'
      -- GLOBAL RULE: exclude processed/ and error/ workflow-prefix objects.
      AND NOT regexp_like(lower(i.key), '^(processed|error)/')
      AND NOT regexp_like(lower(i.key), '(^|/)backload/')
),
volume AS (
    SELECT
        k.aa,
        count_if(k.doc_seg = 'ccd') AS ccd,
        count_if(k.doc_seg = 'trn') AS trn,
        count_if(k.doc_seg = 'lab') AS lab,
        count_if(k.doc_seg = 'oru') AS oru,
        array_join(array_sort(array_distinct(array_agg(k.bucket_qe))), ',') AS volume_bucket_qes
    FROM key_parts k
    CROSS JOIN config c
    WHERE k.submission_date IS NOT NULL
      AND k.submission_date >= DATE '2026-03-12'
      AND k.submission_date >= c.window_start
      AND k.submission_date <  c.window_end_exclusive
      AND k.doc_seg IN ('ccd', 'trn', 'lab', 'oru')
    GROUP BY k.aa
),

-- Every (AA, hospital) pairing on the roster, SPARCS hospitals only.
roster_all AS (
    SELECT
        upper(trim(h.code)) AS aa,
        h.nys_facility_id,
        array_join(array_sort(array_distinct(array_agg(m.qe_short))), '/') AS qe,
        min(trim(h.organization_name)) AS hospital_name,
        max(TRY_CAST(nullif(trim(h.scaler_size), '') AS integer)) AS sparcs_size
    FROM lookup_hospital_assigning_authorities h
    JOIN qe_map m ON h.qe_name = m.roster_qe
    WHERE lower(h.organization_type) LIKE '%hospital%'
      AND lower(trim(coalesce(h.code_level, ''))) <> 'sub-facility'
      AND lower(trim(coalesce(h.code_status, ''))) = 'active'
      AND lower(trim(coalesce(h.organization_status, ''))) = 'active'
      AND trim(coalesce(h.participating, '')) = '1'
      AND h.code IS NOT NULL AND trim(h.code) <> ''
    GROUP BY upper(trim(h.code)), h.nys_facility_id
    -- A real hospital is one SPARCS knows: it must carry a SPARCS size.
    HAVING max(TRY_CAST(nullif(trim(h.scaler_size), '') AS integer)) > 0
),

-- Every AA the roster lists for each hospital (for transparency).
facility_aas AS (
    SELECT nys_facility_id,
           array_join(array_sort(array_agg(aa)), ',') AS roster_aas_listed
    FROM roster_all
    GROUP BY nys_facility_id
),

-- Assign each hospital to ONE AA: the listed AA with the most volume in the
-- window; ties and silent AAs fall back to the alphabetically first AA.
-- The volume is joined here, in the ONLY place the volume CTE is used, so the
-- snapshot is read once. Volume is per AA, so it rides along with each row.
roster AS (
    SELECT aa, nys_facility_id, qe, hospital_name, sparcs_size,
           ccd, trn, lab, oru, volume_bucket_qes
    FROM (
        SELECT
            ra.*,
            coalesce(v.ccd, 0) AS ccd,
            coalesce(v.trn, 0) AS trn,
            coalesce(v.lab, 0) AS lab,
            coalesce(v.oru, 0) AS oru,
            coalesce(v.volume_bucket_qes, '(none)') AS volume_bucket_qes,
            row_number() OVER (
                PARTITION BY ra.nys_facility_id
                ORDER BY coalesce(v.ccd + v.trn + v.lab + v.oru, 0) DESC, ra.aa ASC
            ) AS rn
        FROM roster_all ra
        LEFT JOIN volume v ON v.aa = ra.aa
    ) t
    WHERE rn = 1
),

-- System (AA) totals: SUM of SPARCS across the AA's hospitals. The AA's volume is
-- the same on every one of its rows, so max() simply picks it up.
chain_vol AS (
    SELECT
        aa,
        array_join(array_sort(array_distinct(flatten(array_agg(split(qe, '/'))))), '/') AS qe,
        count(*) AS chain_hospital_count,
        sum(sparcs_size) AS chain_sparcs_sum,
        -- Guess at the system name: its largest hospital, with the AA appended.
        max_by(hospital_name, sparcs_size) || ' (' || aa || ')' AS chain_name,
        max(ccd) AS chain_ccd,
        max(trn) AS chain_trn,
        max(lab) AS chain_lab,
        max(oru) AS chain_oru,
        max(volume_bucket_qes) AS volume_bucket_qes
    FROM roster
    GROUP BY aa
),

ranked AS (
    SELECT
        cv.*,
        RANK() OVER (ORDER BY chain_sparcs_sum DESC) AS size_rank_overall,
        RANK() OVER (PARTITION BY qe ORDER BY chain_sparcs_sum DESC) AS size_rank_in_qe,
        RANK() OVER (ORDER BY chain_ccd DESC) AS ccd_rank,
        RANK() OVER (ORDER BY chain_trn DESC) AS trn_rank,
        RANK() OVER (ORDER BY chain_lab DESC) AS lab_rank
    FROM chain_vol cv
)

SELECT
    r.qe,
    r.chain_name,
    r.aa AS chain_aa,
    ro.hospital_name,
    ro.nys_facility_id,
    fa.roster_aas_listed,
    CASE WHEN r.chain_ccd > 0 THEN 'Y' ELSE 'N' END AS sends_ccd,
    CASE WHEN r.chain_trn > 0 THEN 'Y' ELSE 'N' END AS sends_trn,
    CASE WHEN r.chain_lab > 0 THEN 'Y' ELSE 'N' END AS sends_lab,
    CASE WHEN r.chain_oru > 0 THEN 'Y' ELSE 'N' END AS sends_oru,
    ro.sparcs_size AS hospital_sparcs_size,
    CASE WHEN ro.sparcs_size >= 8 THEN '03-Large'
         WHEN ro.sparcs_size >= 4 THEN '02-Medium'
         ELSE '01-Small' END AS hospital_size_tier,
    r.chain_hospital_count,
    r.chain_sparcs_sum,
    CASE WHEN r.chain_sparcs_sum >= 8 THEN '03-Large'
         WHEN r.chain_sparcs_sum >= 4 THEN '02-Medium'
         ELSE '01-Small' END AS chain_size_tier,
    r.size_rank_overall,
    r.size_rank_in_qe,
    r.chain_ccd,
    r.chain_trn,
    r.chain_lab,
    r.chain_oru,
    -- Annualized: (28-day count / 28) * 365. Directional, not exact.
    CAST(round(1.0 * r.chain_ccd / cfg.window_days * 365) AS bigint) AS annual_ccd,
    CAST(round(1.0 * r.chain_trn / cfg.window_days * 365) AS bigint) AS annual_trn,
    CAST(round(1.0 * r.chain_lab / cfg.window_days * 365) AS bigint) AS annual_lab,
    CAST(round(1.0 * r.chain_oru / cfg.window_days * 365) AS bigint) AS annual_oru,
    r.volume_bucket_qes,
    r.ccd_rank,
    (r.ccd_rank - r.size_rank_overall) AS ccd_gap,
    r.trn_rank,
    (r.trn_rank - r.size_rank_overall) AS trn_gap,
    r.lab_rank,
    (r.lab_rank - r.size_rank_overall) AS lab_gap,
    round(1.0 * r.chain_ccd / cfg.window_days * 365 / r.chain_sparcs_sum, 1) AS annual_ccd_per_sparcs_point,
    CASE WHEN row_number() OVER (
             PARTITION BY r.aa
             ORDER BY ro.sparcs_size DESC, ro.hospital_name
         ) = 1 THEN 1 ELSE 0 END AS count_chain_once
FROM ranked r
CROSS JOIN config cfg
JOIN roster ro ON ro.aa = r.aa
JOIN facility_aas fa ON fa.nys_facility_id = ro.nys_facility_id
ORDER BY r.qe ASC, r.size_rank_in_qe ASC, r.aa ASC, ro.sparcs_size DESC, ro.hospital_name ASC
