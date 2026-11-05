/*
Expected cost/run: ~$0.30-0.60 (ONE inventory snapshot partition)
Expected runtime: ~1-2 minutes

Goal:
- Daily count of PDR documents (CCD, TRN, LAB) by QE over the last 28 days
  (4 full weeks — captures weekly rhythm and holiday dips), for loading into
  Excel to forecast/project future volume.
- Output columns: date, qe, ccd_in_pdr, trn_in_pdr, lab_in_pdr (one row per
  day + QE).

SINGLE-SNAPSHOT APPROACH (why this is cheap):
- PDR never deletes data, so ONE recent, complete inventory snapshot already
  contains every document ever written. We therefore read just ONE partition
  (default: 5 days ago, to be safely past inventory lag) instead of one snapshot
  per day.
- The per-day counts come from the TRUE submission date parsed from the S3 key
  path (<AA>/<type>/YYYY/Mon/DD/...), NOT last_modified_date (which is
  re-stamped by routine S3 rewrites — see rules.md). So one snapshot yields a
  correct daily series for any window it covers.
- The reporting window is anchored to the SNAPSHOT (not today) and ends the day
  BEFORE the snapshot, so the partial snapshot-edge day is excluded and every
  reported day is complete.

Standing rules applied (see rules.md):
- Submission date parsed from the key path; window = last 28 complete days
  (ending the day before the snapshot).
- EXCLUDE data before 2026-03-12 (conservative header-only "bad date" floor;
  that is when the header-without-document issue was fixed).
- EXCLUDE backload and the processed/ and error/ workflow prefixes.
- EXCLUDE orphan sources (not in the Verato MPI) via an INNER JOIN to
  lookup_verato_aa, so only Verato-matched sources are counted. This is
  self-maintaining (no hardcoded orphan list) and uses the standard AA
  normalization (strip .DUPLICATE* suffixes; for BRONX treat underscores as
  spaces; case-insensitive).
*/

WITH config AS (
    SELECT
        28 AS lookback_days,                          -- << number of complete days to report (4 weeks: captures weekly + holiday patterns)
        date_add('day', -5, current_date) AS snapshot_day,  -- << one recent snapshot (5 days ago)
        -- The snapshot's dt partition.
        date_format(date_add('day', -5, current_date), '%Y-%m-%d-01-00') AS single_snapshot_dt,
        -- Window is anchored to the SNAPSHOT, not today: a 5-day-old snapshot only
        -- contains submissions through roughly its own date, and the snapshot's own
        -- day is partial (edge tail-off). So we end the window the day BEFORE the
        -- snapshot (last complete day) and go back lookback_days from there.
        date_add('day', -5, current_date)                       AS window_end_exclusive,  -- snapshot_day (exclusive upper bound)
        date_add('day', -(5 + 28), current_date)                AS window_start           -- snapshot_day - lookback_days
),

-- Map PDR bucket QE names to Verato QE names.
qe_name_map AS (
    SELECT pdr_name, verato_name
    FROM (VALUES
        ('bronx',              'BRONX'),
        ('rochester',          'GRRHIO'),
        ('healtheconnections', 'HECDCS'),
        ('healthix',           'HEALTHIX'),
        ('hixny',              'HIXNY'),
        ('techbd',             'TXD'),
        ('healthelink',        'HEALTHELINK')
    ) AS t(pdr_name, verato_name)
),

-- Pre-normalize Verato AAs once so the big join is plain equality.
verato_norm AS (
    SELECT DISTINCT
        lower(m.pdr_name) AS pdr_qe,
        upper(
            CASE
                WHEN upper(m.verato_name) = 'BRONX'
                THEN replace(regexp_replace(v.assigning_authority,
                        '\.(DUPLICATE|DUPLICATE1|DUPLICATE2|DUPLICATE3)$', ''), '_', ' ')
                ELSE regexp_replace(v.assigning_authority,
                        '\.(DUPLICATE|DUPLICATE1|DUPLICATE2|DUPLICATE3)$', '')
            END
        ) AS aa_key
    FROM pdr_inventory.lookup_verato_aa v
    JOIN qe_name_map m
        ON upper(v.qe) = upper(m.verato_name)
),

-- Parse each key ONCE into lowercase path segments (cheap vs. many regex over
-- the full key). Key shape: <seg1>/<seg2>/<seg3>/...  seg1 = AA, or a workflow
-- prefix (backload) with the AA in seg2. processed/error are already excluded.
key_parts AS (
    SELECT
        regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS qe,
        lower(split_part(i.key, '/', 1)) AS seg1,
        lower(split_part(i.key, '/', 2)) AS seg2,
        lower(split_part(i.key, '/', 3)) AS seg3,
        split_part(i.key, '/', 1) AS seg1_raw,
        split_part(i.key, '/', 2) AS seg2_raw,
        -- TRUE submission date from the key path (never changes on rewrite).
        TRY(date_parse(
            regexp_extract(i.key, '(?i)(?:ccd|trn|lab|oru)/(\d{4}/[A-Za-z]{3}/\d{2})/', 1),
            '%Y/%b/%d'
        )) AS submission_date
    FROM pdr_inventory.pdr_inventory_prod_data_all i
    CROSS JOIN config c
    WHERE
        i.dt = c.single_snapshot_dt
        AND i.bucket LIKE 'nyec-pdr-prod-%'
        AND i.is_latest = true
        AND coalesce(i.is_delete_marker, false) = false
        -- Scan reducer (re-stamps only move dates forward, so this never drops a
        -- valid row); real floor is applied on submission_date below.
        AND i.last_modified_date >= timestamp '2026-03-12 00:00:00'
        -- GLOBAL RULE: exclude processed/ and error/ workflow-prefix objects.
        AND lower(split_part(i.key, '/', 1)) NOT IN ('processed', 'error')
        -- Exclude backload.
        AND NOT regexp_like(lower(i.key), '(^|/)backload/')
),

-- Derive AA + data type from the parsed segments. Doc type is the segment after
-- the AA (seg2 on a normal path).
pdr_docs AS (
    SELECT
        submission_date,
        qe,
        upper(trim(seg1_raw)) AS assigning_authority,
        CASE seg2 WHEN 'ccd' THEN 'CCD' WHEN 'trn' THEN 'TRN' WHEN 'lab' THEN 'LAB' END AS data_type
    FROM key_parts
    CROSS JOIN config c
    WHERE submission_date IS NOT NULL
      AND submission_date >= DATE '2026-03-12'
      -- 10 COMPLETE days anchored to the snapshot: [snapshot_day - 10, snapshot_day),
      -- which excludes the partial snapshot-edge day.
      AND submission_date >= c.window_start
      AND submission_date <  c.window_end_exclusive
),

-- Keep ONLY sources present in Verato (excludes orphans).
in_verato AS (
    SELECT d.submission_date, d.qe, d.data_type
    FROM pdr_docs d
    JOIN verato_norm vn
        ON lower(d.qe) = vn.pdr_qe
        AND d.assigning_authority = vn.aa_key
    WHERE d.data_type IS NOT NULL
)

SELECT
    date_format(submission_date, '%Y-%m-%d') AS date,
    qe,
    count_if(data_type = 'CCD') AS ccd_in_pdr,
    count_if(data_type = 'TRN') AS trn_in_pdr,
    count_if(data_type = 'LAB') AS lab_in_pdr
FROM in_verato
GROUP BY submission_date, qe
ORDER BY date ASC, qe ASC;
