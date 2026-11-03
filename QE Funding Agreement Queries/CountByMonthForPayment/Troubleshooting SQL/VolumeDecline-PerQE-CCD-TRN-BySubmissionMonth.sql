/*
Per-QE CCD & TRN volume by SUBMISSION MONTH - the query behind the
"Broad September volume decline" memo (ISSUE-PDR-Volume-Decline-Sept2026.md).

Dating:
- Each document is dated by the TRUE submission date parsed from the S3 KEY PATH
  (<type>/YYYY/Mon/DD/), e.g. MMC/trn/2026/Aug/15/12/... We intentionally do NOT
  use last_modified_date: PDR updates S3 object attributes independently of
  submission (metadata changes, bulk operations), which re-stamps
  last_modified_date and makes it unreliable as a submission date. The key path
  is written at submission time and never changes.

Scope (so this is a real, current-state finding):
- Orphans EXCLUDED: only sources matching the Verato MPI (lookup_verato_aa),
  with the standard AA normalization.
- Backload EXCLUDED: real-time/normal submissions only.
- Header-only period EXCLUDED: nothing before 2026-03-11 (see rules.md).
- Reads ONE recent inventory snapshot (dt = yesterday's partition).

Output: one row per QE + data type, with monthly counts Jun-Oct 2026.
*/
WITH qe_name_map AS (
    SELECT pdr_name, verato_name FROM (VALUES
        ('bronx','BRONX'),('rochester','GRRHIO'),('healtheconnections','HECDCS'),
        ('healthix','HEALTHIX'),('hixny','HIXNY'),('techbd','TXD'),('healthelink','HEALTHELINK')
    ) AS t(pdr_name, verato_name)
),
verato_norm AS (
    SELECT DISTINCT lower(m.pdr_name) AS pdr_qe,
        upper(CASE WHEN upper(m.verato_name) = 'BRONX'
            THEN replace(regexp_replace(v.assigning_authority,'\.(DUPLICATE|DUPLICATE1|DUPLICATE2|DUPLICATE3)$',''),'_',' ')
            ELSE regexp_replace(v.assigning_authority,'\.(DUPLICATE|DUPLICATE1|DUPLICATE2|DUPLICATE3)$','') END) AS aa_key
    FROM pdr_inventory.lookup_verato_aa v
    JOIN qe_name_map m ON upper(v.qe) = upper(m.verato_name)
),
base AS (
    SELECT
        date_format(
            TRY(date_parse(regexp_extract(key,'(?i)(?:ccd|trn|lab|oru)/(\d{4}/[A-Za-z]{3}/\d{2})/',1),'%Y/%b/%d')),
            '%Y-%m'
        ) AS month,
        CASE
            WHEN regexp_like(lower(key),'(^|/)ccd(/|$)') THEN 'CCD'
            WHEN regexp_like(lower(key),'(^|/)trn(/|$)') THEN 'TRN'
        END AS dtype,
        regexp_replace(regexp_replace(bucket,'^nyec-pdr-prod-',''),'-part2$','') AS qe,
        upper(trim(CASE
            WHEN lower(split_part(key,'/',1)) IN ('processed','error','backload') THEN split_part(key,'/',2)
            ELSE split_part(key,'/',1) END)) AS aa
    FROM pdr_inventory.pdr_inventory_prod_data_all
    WHERE dt = date_format(date_add('day',-2,current_date),'%Y-%m-%d-01-00')
        AND bucket LIKE 'nyec-pdr-prod-%'
        AND is_latest = true
        AND coalesce(is_delete_marker,false) = false
        -- Scan reducer only (re-stamps move dates forward; see rules.md).
        AND last_modified_date >= timestamp '2026-03-11 00:00:00'
        AND NOT regexp_like(lower(key),'(^|/)backload/')
        AND (regexp_like(lower(key),'(^|/)ccd(/|$)') OR regexp_like(lower(key),'(^|/)trn(/|$)'))
)
SELECT
    b.qe,
    b.dtype,
    count_if(month = '2026-06') AS jun,
    count_if(month = '2026-07') AS jul,
    count_if(month = '2026-08') AS aug,
    count_if(month = '2026-09') AS sep,
    count_if(month = '2026-10') AS oct
FROM base b
-- Orphans excluded: keep only sources present in Verato.
JOIN verato_norm vn ON lower(b.qe) = vn.pdr_qe AND b.aa = vn.aa_key
WHERE b.dtype IS NOT NULL
GROUP BY b.qe, b.dtype
ORDER BY b.qe, b.dtype;
