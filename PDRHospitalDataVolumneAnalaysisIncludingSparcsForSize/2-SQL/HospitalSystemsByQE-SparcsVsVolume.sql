/*
Expected cost/run: ~$1.15 (ONE inventory snapshot; Athena reads it five times,
~234 GB)
Expected runtime: ~3-4 minutes

ANNUALIZING (directionally accurate, not exact)
- PDR never deletes data, so any recent inventory snapshot holds everything. We
  read ONE snapshot from about a week ago, count 28 complete days of documents,
  and project a year:  annual = (28-day count / 28) * 365.

MACRO QUESTION
- Are the BIG hospital systems (by SPARCS size) the BIG contributors of CCD, LAB,
  TRN and ADT, and the small systems small? Which send each type, and which send
  none?

THE KEY: ASSIGNING AUTHORITY (AA)
- An AA is, at its core, an EPIC instance. Everything that instance sends reaches
  PDR under one AA, so the AA is what binds the data together.
- One AA commonly serves SEVERAL hospitals. SPARCS counts those hospitals
  SEPARATELY, but PDR volume only arrives per AA, so volume is shown per AA.
- A "system" (chain) = one AA. It can be a single hospital.

ONE ROW PER HOSPITAL PER AA
- A hospital can use more than one AA, and each AA gets its own row so the data
  lands on the AA that really carries it. The ~194 distinct hospitals are the
  same; there are simply more rows. A hospital's AAs come from three places
  (aa_source says which):
    roster (Salesforce)  the AA code in the Salesforce roster
    ADT file             the AA the hospital uses in the ADT counts file
                         (pdr_inventory.lookup_adt_counts). This is the AA
                         currently in use, so it catches roster codes that went
                         stale (HealtheConnections moved from numeric codes to
                         names such as UPSTATE, GUTHRIE, CENTRALUS-3).
    hixny-DOC            for Hixny hospitals only: the base AA with "DOC" added
                         (MIB -> MIBDOC). Hixny files its CCDs under the DOC AA
                         and everything else (TRN, LAB, ADT) under the base AA.
                         The DOC row is shown only when documents exist.
  When an AA is in more than one source, aa_source shows both.
- Example, a Hixny hospital:      MIB      -> TRN, LAB, ADT
                                  MIBDOC   -> CCD
- Example, a HealtheConnections hospital (Crouse, facility 636):
                                  CROUSE         -> ADT-file AA, the real CCD/TRN/LAB/ADT
                                  CROUSE-HOSP-2  -> dead Salesforce code, no data (hidden)
                                  CROUSE-HOSP-3  -> dead Salesforce code, no data (hidden)
- SILENT AA ROWS ARE HIDDEN: an AA that sends no CCD, TRN, LAB or ADT at all is not
  shown as a row when the same hospital has data on another AA, so one hospital
  does not look like several chains with N N N N rows beside the real one. A
  hospital is never left without a row: if NONE of its AAs has data, its silent
  row(s) stay so it shows up as a zero. Nothing is lost: hospital_aas still lists
  every AA the hospital is known by (including the hidden ones), which is the list
  of codes Salesforce needs to refresh. AA-level totals are unaffected.

WHICH HOSPITALS ARE IN THE REPORT (~194 distinct)
- The SFDC roster holds more than hospitals (imaging centers, extension clinics,
  off-campus EDs). A real hospital is one SPARCS knows, so a hospital is kept
  ONLY if the roster carries a SPARCS size (scaler_size > 0) for its NYS
  Facility ID.

HOW TO COUNT WITHOUT DOUBLE COUNTING
- AA-level values (annual_ccd, annual_trn, annual_lab, annual_adt, chain_*) repeat
  on every hospital row of that AA. Sum them over rows with count_chain_once = 1.
- To count hospitals, use rows with count_hospital_once = 1 (one per hospital).
- hospital_annual_adt is ADT for this hospital on this AA, so it can be summed
  over ALL rows.
- A hospital on more than one AA adds its SPARCS size to each AA's total.

SNIFF TESTS (ccd_sniff, adt_sniff, oru_sniff): "is this system sending about what
its SPARCS size says it should?"
- Done per system (AA) and repeated on each of its hospital rows. ORU = LAB, so
  oru_sniff is measured on the lab-results volume.
- For each type only the systems that SUBMIT that type are ranked:
      size rank   = rank by summed SPARCS size (biggest = 1)
      volume rank = rank by actual volume of the type (most = 1)
      gap         = volume rank - size rank
  A big system sending little of a type has a big positive gap.
- Result:
      NULL    the system sends none of that type (nothing to test), or it is a
              PART 2 AA (code ends in -2), which is skipped and not ranked
      'pass'  gap is under 20 places (sniff_gap_limit in the config block)
      'fail'  gap is 20 places or more (far less data than a system of that size
              should send)
  A negative gap (more data than the size predicts) always passes.
- The limit counts places within the list of senders of that type, so it is a bigger
  slice of a short list (CCD has far fewer senders than ADT). Change sniff_gap_limit
  to tighten or loosen.

COLUMNS, in output order:
  qe, chain_name, chain_aa, hospital_name, nys_facility_id,
  chain_size_tier, sends_ccd, sends_trn, sends_lab, sends_adt, hospital_size_tier,
  ccd_sniff, adt_sniff, oru_sniff, then aa_source, hospital_aas, hospital_aa_count,
  chain_hospital_count, annual_ccd, annual_trn, annual_lab, annual_adt,
  hospital_annual_adt, volume_bucket_qes, count_chain_once, count_hospital_once.
- hospital_aas is every AA the hospital is known by: the Salesforce roster AAs, plus
  the ADT-file AAs and the Hixny DOC AA. It includes silent AAs whose rows are
  hidden, so it can list more AAs than the hospital has rows; hospital_aa_count
  is the matching count.
- qe (the QE of the AA: the roster's QE when the roster lists the AA, otherwise
  the QE in the ADT file - TXD/techbd is shown as healthelink - and Hixny for DOC
  rows. Every hospital row of an AA shows the same label, "a/b" when its
  hospitals come through two QEs. A hospital listed under two QEs therefore has
  each of its AA rows under that AA's QE, so a QE's hospital count can include
  hospitals that also appear under another QE.),
  chain_name (guess = the AA's largest hospital + AA), chain_aa, aa_source,
  hospital_name, nys_facility_id
- hospital_aas (every AA this hospital is known by, incl. hidden silent ones), hospital_aa_count
- sends_ccd, sends_trn, sends_lab, sends_adt (Y/N: does this AA send that type at
  all in the window). LAB = lab results (ORU messages); in PDR they sit under the
  `lab` path segment, so there is no separate ORU column.
- hospital_size_tier (01-Small = SPARCS size 1 to 3, 02-Medium = 4 to 7,
  03-Large = 8 to 10), chain_hospital_count, chain_size_tier (same cutoffs on the
  AA's SUMMED hospital size)
- annual_ccd, annual_trn, annual_lab (AA level; 28-day count / 28 * 365)
- annual_adt (AA level) and hospital_annual_adt (this hospital on this AA): ADT
  messages annualized = (messages / days covered by the ADT file) * 365. Today the
  file covers Aug-Oct 2026 = 92 days. ADT is joined on NYS facility ID plus the
  AA in the ADT file. Repeat rows that differ only in name spelling are collapsed
  (max, not sum); a hospital reporting the same AA through two QEs has both
  streams added. See MakeTableQueryADT.sql.
- volume_bucket_qes: the PDR bucket(s) the AA's documents actually land in
- count_chain_once, count_hospital_once (see above)
- The ranks and gaps behind the sniff tests are calculated inside the query but not
  output. They are done only among the systems that send each type, because with
  several rows per hospital (a Hixny DOC row has CCD but no TRN/LAB, its base row the
  reverse) a gap against a list that includes non-senders would read as a false problem.

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
        28 AS window_days,
        -- SNIFF TEST: a system FAILS when its rank by actual volume is this many places
        -- (or more) worse than its rank by SPARCS size. Change here to tighten/loosen.
        20 AS sniff_gap_limit
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

-- ADT message counts (monthly, per hospital) from the S3 lookup file. Some rows
-- repeat exactly except for the spelling of the name, so collapse on
-- month + QE + facility + AA taking max (NOT sum).
adt_dedup AS (
    SELECT
        CAST(message_month AS date) AS m,
        upper(trim(originating_qe)) AS adt_qe,
        trim(nys_permanent_facility_id) AS fac,
        upper(trim(assigning_authority)) AS adt_aa,
        max(CAST(message_count AS bigint)) AS msgs
    FROM pdr_inventory.lookup_adt_counts
    GROUP BY 1, 2, 3, 4
),
-- Days covered by the ADT file (all months present), used to annualize:
-- annual = (messages / days covered) * 365.
adt_days AS (
    SELECT sum(day(last_day_of_month(m))) AS days
    FROM (SELECT DISTINCT m FROM adt_dedup)
),
-- ADT per hospital per AA (a hospital reporting the same AA through two QEs has
-- both streams added).
adt_by_fac_aa AS (
    SELECT fac, adt_aa, sum(msgs) AS adt_total
    FROM adt_dedup
    GROUP BY fac, adt_aa
),

-- Volume from ONE snapshot, dated by the key-path submission date.
key_parts AS (
    SELECT
        regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS bucket_qe,
        upper(trim(split_part(i.key, '/', 1))) AS aa,
        lower(split_part(i.key, '/', 2)) AS doc_seg,
        TRY(date_parse(
            regexp_extract(i.key, '(?i)(?:ccd|trn|lab)/(\d{4}/[A-Za-z]{3}/\d{2})/', 1),
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
-- Document volume per AA (every AA kept exactly as filed, DOC AAs included).
volume AS (
    SELECT
        k.aa,
        count_if(k.doc_seg = 'ccd') AS ccd,
        count_if(k.doc_seg = 'trn') AS trn,
        count_if(k.doc_seg = 'lab') AS lab,
        array_join(array_sort(array_distinct(array_agg(k.bucket_qe))), ',') AS volume_bucket_qes
    FROM key_parts k
    CROSS JOIN config c
    WHERE k.submission_date IS NOT NULL
      AND k.submission_date >= DATE '2026-03-12'
      AND k.submission_date >= c.window_start
      AND k.submission_date <  c.window_end_exclusive
      AND k.doc_seg IN ('ccd', 'trn', 'lab')
    GROUP BY k.aa
),

-- (1) Every (AA, hospital) pairing on the Salesforce roster, SPARCS hospitals only.
roster_pairs AS (
    SELECT
        upper(trim(h.code)) AS aa,
        trim(h.nys_facility_id) AS nys_facility_id,
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
    GROUP BY upper(trim(h.code)), trim(h.nys_facility_id)
    -- A real hospital is one SPARCS knows: it must carry a SPARCS size.
    HAVING max(TRY_CAST(nullif(trim(h.scaler_size), '') AS integer)) > 0
),
-- One row per hospital: its QE label, name and SPARCS size.
fac_base AS (
    SELECT
        nys_facility_id,
        array_join(array_sort(array_distinct(flatten(array_agg(split(qe, '/'))))), '/') AS qe,
        min(hospital_name) AS hospital_name,
        max(sparcs_size) AS sparcs_size
    FROM roster_pairs
    GROUP BY nys_facility_id
),
-- (2) AAs the hospital actually uses in the ADT file. The row's QE is the ADT
-- file's originating QE, mapped to our short names (TXD/techbd carries the
-- HEALTHeLINK hospitals, so it is shown as healthelink).
adt_pairs AS (
    SELECT
        a.adt_aa AS aa,
        a.fac AS nys_facility_id,
        array_join(array_sort(array_distinct(array_agg(
            CASE a.adt_qe
                WHEN 'HECDCS'   THEN 'healtheconnections'
                WHEN 'HIXNY'    THEN 'hixny'
                WHEN 'HEALTHIX' THEN 'healthix'
                WHEN 'BRONX'    THEN 'bronx'
                WHEN 'GRRHIO'   THEN 'rochester'
                WHEN 'TXD'      THEN 'healthelink'
                ELSE lower(a.adt_qe)
            END))), '/') AS qe
    FROM adt_dedup a
    JOIN fac_base fb ON fb.nys_facility_id = a.fac
    GROUP BY a.adt_aa, a.fac
),
-- Roster + ADT-file pairs with a flag for where each came from, and the QE of
-- that source.
base_pairs AS (
    SELECT aa, nys_facility_id, qe, true AS in_roster, false AS in_adt, false AS in_doc FROM roster_pairs
    UNION ALL
    SELECT aa, nys_facility_id, qe, false AS in_roster, true AS in_adt, false AS in_doc FROM adt_pairs
),
-- (3) HIXNY DOC RULE: for Hixny AAs, the base AA with "DOC" added (MIB ->
-- MIBDOC). Hixny files CCDs under the DOC AA. Empty DOC rows are dropped below.
doc_pairs AS (
    SELECT DISTINCT bp.aa || 'DOC' AS aa, bp.nys_facility_id, 'hixny' AS qe,
           false AS in_roster, false AS in_adt, true AS in_doc
    FROM base_pairs bp
    WHERE bp.qe LIKE '%hixny%'
      AND bp.aa NOT LIKE '%DOC'
),
-- One row per (AA, hospital). Its QE label is the roster's when the roster lists
-- the AA, otherwise the ADT file's, otherwise Hixny (DOC).
pair_flags AS (
    SELECT aa, nys_facility_id,
           coalesce(max(CASE WHEN in_roster THEN qe END),
                    max(CASE WHEN in_adt THEN qe END),
                    max(qe)) AS qe,
           bool_or(in_roster) AS in_roster, bool_or(in_adt) AS in_adt, bool_or(in_doc) AS in_doc
    FROM (
        SELECT * FROM base_pairs
        UNION ALL
        SELECT * FROM doc_pairs
    ) t
    GROUP BY aa, nys_facility_id
),

-- Every (hospital, AA) row with that AA's volume and that hospital's ADT on it.
-- The volume CTE is used here, and only here.
pair_rows AS (
    SELECT
        pf.aa,
        pf.nys_facility_id,
        pf.qe,
        fb.hospital_name,
        fb.sparcs_size,
        coalesce(v.ccd, 0) AS ccd,
        coalesce(v.trn, 0) AS trn,
        coalesce(v.lab, 0) AS lab,
        coalesce(v.volume_bucket_qes, '(none)') AS volume_bucket_qes,
        coalesce(a.adt_total, 0) AS adt_total,
        CASE
            WHEN pf.in_roster AND pf.in_adt THEN 'roster + ADT file'
            WHEN pf.in_roster THEN 'roster (Salesforce)'
            WHEN pf.in_adt THEN 'ADT file'
            ELSE 'hixny-DOC'
        END AS aa_source
    FROM pair_flags pf
    JOIN fac_base fb ON fb.nys_facility_id = pf.nys_facility_id
    LEFT JOIN volume v ON v.aa = pf.aa
    LEFT JOIN adt_by_fac_aa a ON a.fac = pf.nys_facility_id AND a.adt_aa = pf.aa
    -- Drop a Hixny DOC row when no documents exist under that DOC AA.
    WHERE NOT (pf.in_doc AND NOT pf.in_roster AND NOT pf.in_adt
               AND coalesce(v.ccd + v.trn + v.lab, 0) = 0)
),

-- All the AAs a hospital has a row for.
hospital_aas AS (
    SELECT nys_facility_id,
           array_join(array_sort(array_agg(aa)), ',') AS hospital_aas,
           count(*) AS hospital_aa_count
    FROM pair_rows
    GROUP BY nys_facility_id
),

-- AA (system) totals: SUM of SPARCS across the AA's hospitals; the AA's volume is
-- the same on each of its rows, so max() simply picks it up.
chain_vol AS (
    SELECT
        aa,
        -- ONE QE label per AA (every hospital row of the AA shows the same one), so
        -- AA-level volume is never split across QEs.
        array_join(array_sort(array_distinct(flatten(array_agg(split(qe, '/'))))), '/') AS qe,
        count(*) AS chain_hospital_count,
        sum(sparcs_size) AS chain_sparcs_sum,
        -- Guess at the system name: its largest hospital, with the AA appended.
        max_by(hospital_name, sparcs_size) || ' (' || aa || ')' AS chain_name,
        max(ccd) AS chain_ccd,
        max(trn) AS chain_trn,
        max(lab) AS chain_lab,
        -- ADT is per hospital, so the AA total is the SUM of its hospitals.
        sum(adt_total) AS chain_adt_total,
        max(volume_bucket_qes) AS volume_bucket_qes,
        -- PART 2 (substance-use) feeds: HealtheConnections codes ending in -2. They carry
        -- tiny volume by design, so they are left out of the sniff tests.
        (aa LIKE '%-2') AS is_part2
    FROM pair_rows
    GROUP BY aa
),

-- SNIFF-TEST RANKS, one pair per data type (CCD, ADT, LAB/ORU).
-- For each type, only the systems (AAs) that SUBMIT that type are ranked:
--   size rank   = rank by summed SPARCS size, biggest = 1
--   volume rank = rank by actual volume of that type, most = 1
-- A system that sends none of the type is not ranked (its sniff result is NULL).
-- Ranking only the senders keeps a hospital that files its types under different AAs
-- (Hixny: CCD on the DOC AA, everything else on the base AA) from being counted twice
-- in one ranking.
ranked AS (
    SELECT
        cv.*,
        RANK() OVER (PARTITION BY (chain_ccd > 0 AND NOT is_part2) ORDER BY chain_sparcs_sum DESC) AS ccd_size_rank,
        RANK() OVER (PARTITION BY (chain_ccd > 0 AND NOT is_part2) ORDER BY chain_ccd DESC)        AS ccd_vol_rank,
        RANK() OVER (PARTITION BY (chain_adt_total > 0 AND NOT is_part2) ORDER BY chain_sparcs_sum DESC) AS adt_size_rank,
        RANK() OVER (PARTITION BY (chain_adt_total > 0 AND NOT is_part2) ORDER BY chain_adt_total DESC)  AS adt_vol_rank,
        RANK() OVER (PARTITION BY (chain_lab > 0 AND NOT is_part2) ORDER BY chain_sparcs_sum DESC) AS oru_size_rank,
        RANK() OVER (PARTITION BY (chain_lab > 0 AND NOT is_part2) ORDER BY chain_lab DESC)        AS oru_vol_rank
    FROM chain_vol cv
),

-- Hospitals that have data (CCD, TRN, LAB or ADT) on at least one of their AAs.
-- Used below to hide a hospital's SILENT AA rows (dead Salesforce codes such as
-- CROUSE-HOSP-2 next to the live CROUSE), so one hospital does not look like
-- several. A hospital is never left without a row.
hospital_has_data AS (
    SELECT DISTINCT pr.nys_facility_id
    FROM pair_rows pr
    JOIN ranked rk ON rk.aa = pr.aa
    WHERE rk.chain_ccd > 0 OR rk.chain_trn > 0 OR rk.chain_lab > 0 OR rk.chain_adt_total > 0
)

SELECT
    r.qe,
    r.chain_name,
    r.aa AS chain_aa,
    ro.hospital_name,
    ro.nys_facility_id,
    CASE WHEN r.chain_sparcs_sum >= 8 THEN '03-Large'
         WHEN r.chain_sparcs_sum >= 4 THEN '02-Medium'
         ELSE '01-Small' END AS chain_size_tier,
    CASE WHEN r.chain_ccd > 0 THEN 'Y' ELSE 'N' END AS sends_ccd,
    CASE WHEN r.chain_trn > 0 THEN 'Y' ELSE 'N' END AS sends_trn,
    CASE WHEN r.chain_lab > 0 THEN 'Y' ELSE 'N' END AS sends_lab,
    CASE WHEN r.chain_adt_total > 0 THEN 'Y' ELSE 'N' END AS sends_adt,
    CASE WHEN ro.sparcs_size >= 8 THEN '03-Large'
         WHEN ro.sparcs_size >= 4 THEN '02-Medium'
         ELSE '01-Small' END AS hospital_size_tier,
    -- SNIFF TESTS (system / AA level). NULL = this AA sends none of that type.
    -- pass = volume rank is less than sniff_gap_limit places worse than the SPARCS size rank.
    CASE WHEN r.chain_ccd > 0 AND NOT r.is_part2 THEN
         CASE WHEN r.ccd_vol_rank - r.ccd_size_rank < cfg.sniff_gap_limit THEN 'pass' ELSE 'fail' END
    END AS ccd_sniff,
    CASE WHEN r.chain_adt_total > 0 AND NOT r.is_part2 THEN
         CASE WHEN r.adt_vol_rank - r.adt_size_rank < cfg.sniff_gap_limit THEN 'pass' ELSE 'fail' END
    END AS adt_sniff,
    -- ORU = LAB (same thing); measured on the lab-results volume.
    CASE WHEN r.chain_lab > 0 AND NOT r.is_part2 THEN
         CASE WHEN r.oru_vol_rank - r.oru_size_rank < cfg.sniff_gap_limit THEN 'pass' ELSE 'fail' END
    END AS oru_sniff,
    ro.aa_source,
    ha.hospital_aas,
    ha.hospital_aa_count,
    r.chain_hospital_count,
    -- Annualized: (28-day count / 28) * 365. Directional, not exact.
    CAST(round(1.0 * r.chain_ccd / cfg.window_days * 365) AS bigint) AS annual_ccd,
    CAST(round(1.0 * r.chain_trn / cfg.window_days * 365) AS bigint) AS annual_trn,
    CAST(round(1.0 * r.chain_lab / cfg.window_days * 365) AS bigint) AS annual_lab,
    -- ADT annualized: (messages / days covered by the ADT file) * 365.
    -- annual_adt is the AA total; hospital_annual_adt is this hospital on this AA.
    CAST(round(1.0 * r.chain_adt_total / ad.days * 365) AS bigint) AS annual_adt,
    CAST(round(1.0 * ro.adt_total / ad.days * 365) AS bigint) AS hospital_annual_adt,
    r.volume_bucket_qes,
    CASE WHEN row_number() OVER (
             PARTITION BY r.aa
             ORDER BY ro.sparcs_size DESC, ro.hospital_name, ro.nys_facility_id
         ) = 1 THEN 1 ELSE 0 END AS count_chain_once,
    CASE WHEN row_number() OVER (
             PARTITION BY ro.nys_facility_id
             ORDER BY r.aa
         ) = 1 THEN 1 ELSE 0 END AS count_hospital_once
FROM pair_rows ro
JOIN ranked r ON r.aa = ro.aa
JOIN hospital_aas ha ON ha.nys_facility_id = ro.nys_facility_id
LEFT JOIN hospital_has_data hd ON hd.nys_facility_id = ro.nys_facility_id
CROSS JOIN config cfg
CROSS JOIN adt_days ad
-- Hide a SILENT AA row (this AA sends no CCD, TRN, LAB or ADT at all) when the same
-- hospital has data on another AA. Window functions below (count_chain_once,
-- count_hospital_once) are evaluated after this filter, so they stay correct.
WHERE NOT (r.chain_ccd = 0 AND r.chain_trn = 0 AND r.chain_lab = 0 AND r.chain_adt_total = 0
           AND hd.nys_facility_id IS NOT NULL)
ORDER BY r.qe ASC, ro.hospital_name ASC, ro.nys_facility_id ASC, r.aa ASC
