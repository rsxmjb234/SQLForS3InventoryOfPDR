/*
Expected cost/run: ~$0.30 (ONE inventory snapshot partition, ~55-60 GB)
Expected runtime: ~1-2 minutes

Goal:
- ALL-TIME count of documents in PDR by bucket (part2 buckets kept separate), for
  sanity-checking total PDR size against other counts (e.g. Dan's FHIR
  "distinct_messages" by bucket).
- Output: snapshot_dt, bucket, ccd, trn, lab, total, total_in_verato,
  first_submission_date, last_submission_date. Plus an ALL row.

SINGLE-SNAPSHOT APPROACH:
- PDR never deletes data, so ONE recent inventory snapshot holds every document ever
  written. All-time = everything in that snapshot that passes the rules below.

Standing rules applied (see rules.md):
- One snapshot from 5 days ago; is_latest = true; delete markers dropped.
- A document = one S3 object under <AA>/<ccd|trn|lab>/YYYY/Mon/DD/... . Only the
  ccd, trn and lab segments are counted (LAB = ORU).
- Submission date parsed from the key path, NOT last_modified_date.
- EXCLUDE data before 2026-03-12 (header-only "bad date" floor). This also drops the
  old pre-March key layout (<type>/YYYY/Mon/... with 46-byte header-only stubs).
- EXCLUDE backload and the processed/ and error/ workflow prefixes.
- Counted through the day BEFORE the snapshot (the snapshot-edge day is partial).
- total counts every source. total_in_verato keeps only sources found in the Verato
  MPI (orphans excluded), using the standard AA normalization (strip .DUPLICATE*
  suffixes; for BRONX treat underscores as spaces; case-insensitive).
*/

WITH config AS (
    SELECT
        date_format(date_add('day', -5, current_date), '%Y-%m-%d-01-00') AS single_snapshot_dt,
        date_add('day', -5, current_date) AS window_end_exclusive
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

-- Pre-normalized Verato AAs.
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

docs AS (
    SELECT
        i.bucket,
        regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS qe,
        upper(trim(split_part(i.key, '/', 1))) AS assigning_authority,
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
      -- Scan reducer (re-stamps only move dates forward); real floor is on submission_date.
      AND i.last_modified_date >= timestamp '2026-03-12 00:00:00'
      -- GLOBAL RULE: exclude processed/ and error/ workflow-prefix objects.
      AND lower(split_part(i.key, '/', 1)) NOT IN ('processed', 'error')
      -- Exclude backload.
      AND NOT regexp_like(lower(i.key), '(^|/)backload/')
),

counted AS (
    SELECT d.*,
           (vn.aa_key IS NOT NULL) AS in_verato
    FROM docs d
    CROSS JOIN config c
    LEFT JOIN verato_norm vn
        ON lower(d.qe) = vn.pdr_qe
       AND d.assigning_authority = vn.aa_key
    WHERE d.doc_seg IN ('ccd', 'trn', 'lab')
      AND d.submission_date IS NOT NULL
      AND d.submission_date >= DATE '2026-03-12'
      AND d.submission_date <  c.window_end_exclusive
)

SELECT
    (SELECT single_snapshot_dt FROM config) AS snapshot_dt,
    coalesce(bucket, 'ALL') AS bucket,
    count_if(doc_seg = 'ccd') AS ccd,
    count_if(doc_seg = 'trn') AS trn,
    count_if(doc_seg = 'lab') AS lab,
    count(*) AS total,
    count_if(in_verato) AS total_in_verato,
    CAST(min(submission_date) AS date) AS first_submission_date,
    CAST(max(submission_date) AS date) AS last_submission_date
FROM counted
GROUP BY GROUPING SETS ((bucket), ())
ORDER BY (bucket IS NULL) DESC, bucket
