/*
Expected cost/run: ~$0.20 (two single-day snapshots, metadata columns only)
Expected runtime: ~1-2 minutes

Goal:
- Produce copy-paste-ready, plain-English facts about the PDR:
    1. Total documents in the PDR as of the most recent complete snapshot
       (CCD, TRN, labs via the /lab/ path segment) — excluding orphan sources and anything before
       2026-03-11.
    2. Typical daily intake (CCD, TRN, labs) = (today's total - 10-days-ago
       total) / 10.

Rules applied to BOTH counts:
- Excludes documents dated before 2026-03-11 (header-only period).
- Excludes backlog.
- Excludes "orphan" sources — AAs not present in the Verato MPI
  (lookup_verato_aa), using the same normalization as the ExcludeOrphans query:
    * strip Verato suffixes .DUPLICATE / .DUPLICATE1/2/3
    * for QE=BRONX, treat underscores as spaces
    * case-insensitive compare

Output: four ready-to-paste sentences (one per row):
  1. Total documents + average size per type.
  2. Typical daily intake + average size per type.
  3. Approximate AWS S3 storage cost added per month, per type.
  4. AWS S3 forecast: current stored cost, growth, and 12-month projection.

Cost model (settled, "about-ish"): S3 Standard @ $0.023/GB/mo, NO cross-region
replication, so a flat ~1.2x overhead factor covers requests. Storage is
cumulative. The current stored baseline uses the REAL summed bytes from the
snapshot (no approximation). See AWS-Cost-Notes.md for the full writeup.
*/

WITH config AS (
    SELECT
        4  AS recent_lag_days,              -- "today" = current_date - 4 (known-complete snapshot)
        10 AS avg_window_days,              -- daily average window
        2  AS inventory_snapshot_offset_days
),
anchors AS (
    SELECT
        date_add('day', -recent_lag_days, current_date)                      AS recent_day,
        date_add('day', -(recent_lag_days + avg_window_days), current_date)  AS older_day,
        avg_window_days,
        inventory_snapshot_offset_days
    FROM config
),
parts AS (
    SELECT
        recent_day,
        older_day,
        avg_window_days,
        date_format(date_add('day', inventory_snapshot_offset_days, recent_day), '%Y-%m-%d-01-00') AS recent_dt,
        date_format(date_add('day', inventory_snapshot_offset_days, older_day),  '%Y-%m-%d-01-00') AS older_dt
    FROM anchors
),

-- Map PDR bucket QE names to Verato QE names
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

-- Pre-normalize Verato AAs once (small) so the big join is plain equality
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

-- Pull both snapshots, classify type, derive QE + normalized AA
docs AS (
    SELECT
        CASE WHEN i.dt = p.recent_dt THEN 'recent' ELSE 'older' END AS which_snap,
        lower(regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '')) AS qe,
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
            WHEN regexp_like(lower(i.key), '(^|/)lab(/|$)') THEN 'LAB'
        END AS data_type,
        i.size AS size_bytes
    FROM pdr_inventory.pdr_inventory_prod_data_all i
    CROSS JOIN parts p
    WHERE i.dt IN (p.recent_dt, p.older_dt)
        AND i.bucket LIKE 'nyec-pdr-prod-%'
        AND i.is_latest = true
        AND coalesce(i.is_delete_marker, false) = false
        -- PDR data contributed before 2026-03-11 was only the HEADER information, not the clinical document; exclude it.
        AND i.last_modified_date >= timestamp '2026-03-11 00:00:00'
        AND NOT regexp_like(lower(i.key), '(^|/)backload(/|$)')
        AND (
            regexp_like(lower(i.key), '(^|/)ccd(/|$)')
            OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
            OR regexp_like(lower(i.key), '(^|/)lab(/|$)')
        )
),

-- Keep only sources that exist in Verato (exclude orphans)
kept AS (
    SELECT d.which_snap, d.data_type, d.size_bytes
    FROM docs d
    JOIN verato_norm vn
        ON d.qe = vn.pdr_qe
        AND d.aa_key = vn.aa_key
    WHERE d.data_type IS NOT NULL
),

counts AS (
    SELECT
        count_if(which_snap = 'recent' AND data_type = 'CCD') AS recent_ccd,
        count_if(which_snap = 'recent' AND data_type = 'TRN') AS recent_trn,
        count_if(which_snap = 'recent' AND data_type = 'LAB') AS recent_lab,
        count_if(which_snap = 'older'  AND data_type = 'CCD') AS older_ccd,
        count_if(which_snap = 'older'  AND data_type = 'TRN') AS older_trn,
        count_if(which_snap = 'older'  AND data_type = 'LAB') AS older_lab,
        -- Average document size per type (bytes), from the recent snapshot
        avg(CASE WHEN which_snap = 'recent' AND data_type = 'CCD' THEN size_bytes END) AS avg_ccd_bytes,
        avg(CASE WHEN which_snap = 'recent' AND data_type = 'TRN' THEN size_bytes END) AS avg_trn_bytes,
        avg(CASE WHEN which_snap = 'recent' AND data_type = 'LAB' THEN size_bytes END) AS avg_lab_bytes,
        -- Total bytes currently stored per type (recent snapshot)
        sum(CASE WHEN which_snap = 'recent' AND data_type = 'CCD' THEN size_bytes ELSE 0 END) AS total_ccd_bytes,
        sum(CASE WHEN which_snap = 'recent' AND data_type = 'TRN' THEN size_bytes ELSE 0 END) AS total_trn_bytes,
        sum(CASE WHEN which_snap = 'recent' AND data_type = 'LAB' THEN size_bytes ELSE 0 END) AS total_lab_bytes
    FROM kept
),

derived AS (
    SELECT
        recent_ccd, recent_trn, recent_lab,
        recent_ccd + recent_trn + recent_lab AS recent_total,
        CAST(round((recent_ccd - older_ccd) / CAST((SELECT avg_window_days FROM anchors) AS double)) AS bigint) AS ccd_per_day,
        CAST(round((recent_trn - older_trn) / CAST((SELECT avg_window_days FROM anchors) AS double)) AS bigint) AS trn_per_day,
        CAST(round((recent_lab - older_lab) / CAST((SELECT avg_window_days FROM anchors) AS double)) AS bigint) AS lab_per_day,
        -- Average size per type, in KB (rounded)
        CAST(round(avg_ccd_bytes / 1024.0, 1) AS double) AS avg_ccd_kb,
        CAST(round(avg_trn_bytes / 1024.0, 1) AS double) AS avg_trn_kb,
        CAST(round(avg_lab_bytes / 1024.0, 1) AS double) AS avg_lab_kb,
        -- Bytes added PER DAY per type = per-day count * avg bytes
        (round((recent_ccd - older_ccd) / CAST((SELECT avg_window_days FROM anchors) AS double)) * avg_ccd_bytes) AS ccd_bytes_per_day,
        (round((recent_trn - older_trn) / CAST((SELECT avg_window_days FROM anchors) AS double)) * avg_trn_bytes) AS trn_bytes_per_day,
        (round((recent_lab - older_lab) / CAST((SELECT avg_window_days FROM anchors) AS double)) * avg_lab_bytes) AS lab_bytes_per_day,
        -- Currently-stored bytes per type (recent snapshot population)
        total_ccd_bytes, total_trn_bytes, total_lab_bytes,
        (SELECT date_format(recent_day, '%m-%d-%Y') FROM anchors) AS as_of
    FROM counts
),

-- AWS S3 cost model (approximate; S3 Standard, us-east-1)
--   storage: $0.023 per GB per month
cost AS (
    SELECT
        d.*,
        0.023 AS s3_per_gb_month,
        -- GB added per month per type (daily bytes -> GB -> * 30 days)
        (ccd_bytes_per_day / 1073741824.0) * 30 AS ccd_gb_per_month,
        (trn_bytes_per_day / 1073741824.0) * 30 AS trn_gb_per_month,
        (lab_bytes_per_day / 1073741824.0) * 30 AS lab_gb_per_month
    FROM derived d
),

-- Format each number to a rounded short unit: >=1B -> "1.2B", >=1M -> "219M",
-- >=1K -> "450K", else the raw number. Done inline (Athena has no UDFs).
pretty AS (
    SELECT
        as_of,
        -- total
        CASE
            WHEN recent_total >= 1000000000 THEN format('%.1fB', recent_total / 1e9)
            WHEN recent_total >= 1000000    THEN format('%.0fM', recent_total / 1e6)
            WHEN recent_total >= 1000        THEN format('%.0fK', recent_total / 1e3)
            ELSE format('%,d', recent_total)
        END AS total_s,
        CASE
            WHEN recent_ccd >= 1000000000 THEN format('%.1fB', recent_ccd / 1e9)
            WHEN recent_ccd >= 1000000    THEN format('%.0fM', recent_ccd / 1e6)
            WHEN recent_ccd >= 1000        THEN format('%.0fK', recent_ccd / 1e3)
            ELSE format('%,d', recent_ccd)
        END AS ccd_s,
        CASE
            WHEN recent_trn >= 1000000000 THEN format('%.1fB', recent_trn / 1e9)
            WHEN recent_trn >= 1000000    THEN format('%.0fM', recent_trn / 1e6)
            WHEN recent_trn >= 1000        THEN format('%.0fK', recent_trn / 1e3)
            ELSE format('%,d', recent_trn)
        END AS trn_s,
        CASE
            WHEN recent_lab >= 1000000000 THEN format('%.1fB', recent_lab / 1e9)
            WHEN recent_lab >= 1000000    THEN format('%.0fM', recent_lab / 1e6)
            WHEN recent_lab >= 1000        THEN format('%.0fK', recent_lab / 1e3)
            ELSE format('%,d', recent_lab)
        END AS lab_s,
        -- per-day
        CASE
            WHEN ccd_per_day >= 1000000 THEN format('%.1fM', ccd_per_day / 1e6)
            WHEN ccd_per_day >= 1000    THEN format('%.0fK', ccd_per_day / 1e3)
            ELSE format('%,d', ccd_per_day)
        END AS ccd_day_s,
        CASE
            WHEN trn_per_day >= 1000000 THEN format('%.1fM', trn_per_day / 1e6)
            WHEN trn_per_day >= 1000    THEN format('%.0fK', trn_per_day / 1e3)
            ELSE format('%,d', trn_per_day)
        END AS trn_day_s,
        CASE
            WHEN lab_per_day >= 1000000 THEN format('%.1fM', lab_per_day / 1e6)
            WHEN lab_per_day >= 1000    THEN format('%.0fK', lab_per_day / 1e3)
            ELSE format('%,d', lab_per_day)
        END AS lab_day_s,
        -- average sizes (KB)
        format('%.1f', avg_ccd_kb) AS avg_ccd_kb_s,
        format('%.1f', avg_trn_kb) AS avg_trn_kb_s,
        format('%.1f', avg_lab_kb) AS avg_lab_kb_s,
        -- monthly S3 storage cost added per type ($) and total
        format('$%,.2f', ccd_gb_per_month * s3_per_gb_month) AS ccd_cost_s,
        format('$%,.2f', trn_gb_per_month * s3_per_gb_month) AS trn_cost_s,
        format('$%,.2f', lab_gb_per_month * s3_per_gb_month) AS lab_cost_s,
        format('$%,.2f', (ccd_gb_per_month + trn_gb_per_month + lab_gb_per_month) * s3_per_gb_month) AS total_cost_s,
        -- GB added per month per type
        format('%,.1f', ccd_gb_per_month) AS ccd_gb_s,
        format('%,.1f', trn_gb_per_month) AS trn_gb_s,
        format('%,.1f', lab_gb_per_month) AS lab_gb_s,
        format('%,.1f', ccd_gb_per_month + trn_gb_per_month + lab_gb_per_month) AS total_gb_s,
        -- Current stored baseline (real totals from the snapshot, no approximation needed)
        (total_ccd_bytes + total_trn_bytes + total_lab_bytes) / 1073741824.0 AS stored_gb,
        format('%,.1f', (total_ccd_bytes + total_trn_bytes + total_lab_bytes) / 1073741824.0) AS stored_gb_s,
        format('$%,.2f', ((total_ccd_bytes + total_trn_bytes + total_lab_bytes) / 1073741824.0) * s3_per_gb_month) AS stored_cost_now_s,
        -- 12-month storage projection with cumulative ramp, x1.2 overhead (no cross-region replication):
        --   [ current_GB*12  +  monthly_GB*78 ] * $/GB/mo * 1.2
        format('$%,.2f',
            ( (total_ccd_bytes + total_trn_bytes + total_lab_bytes) / 1073741824.0 * 12
              + (ccd_gb_per_month + trn_gb_per_month + lab_gb_per_month) * 78 )
            * s3_per_gb_month * 1.2
        ) AS proj_12mo_s
    FROM cost
)

SELECT 1 AS ord,
    'As of ' || as_of || ' the PDR contained ' || chr(10)
      || total_s || ' documents made up of ' || chr(10)
      || ccd_s || ' CCDs (avg ' || avg_ccd_kb_s || ' KB each)' || chr(10)
      || trn_s || ' TRNs (avg ' || avg_trn_kb_s || ' KB each)' || chr(10)
      || lab_s || ' labs (avg ' || avg_lab_kb_s || ' KB each)' || chr(10)
      || 'Exclusions:' || chr(10)
      || 'Submitted after 2026-03-11 and excluding invalid (non-MPI) sources.'
    AS fact
FROM pretty

UNION ALL

SELECT 2 AS ord,
    'On a typical day the PDR receives' || chr(10)
      || ccd_day_s || ' CCDs (avg ' || avg_ccd_kb_s || ' KB each)' || chr(10)
      || trn_day_s || ' TRNs (avg ' || avg_trn_kb_s || ' KB each)' || chr(10)
      || lab_day_s || ' labs (avg ' || avg_lab_kb_s || ' KB each)' || chr(10)
      || 'Exclusions:' || chr(10)
      || 'Submitted after 2026-03-11 and excluding invalid (non-MPI) sources.'
    AS fact
FROM pretty

UNION ALL

SELECT 3 AS ord,
    'Approximate AWS S3 storage cost added each month (S3 Standard @ $0.023/GB/mo):' || chr(10)
      || 'CCDs: +' || ccd_gb_s || ' GB/mo  ' || ccd_cost_s || '/mo' || chr(10)
      || 'TRNs: +' || trn_gb_s || ' GB/mo  ' || trn_cost_s || '/mo' || chr(10)
      || 'Labs: +' || lab_gb_s || ' GB/mo  ' || lab_cost_s || '/mo' || chr(10)
      || 'TOTAL: +' || total_gb_s || ' GB/mo  ' || total_cost_s || '/mo' || chr(10)
      || 'Note: each month ADDS this much recurring storage cost (cumulative).'
    AS fact
FROM pretty

UNION ALL

SELECT 4 AS ord,
    'AWS S3 forecast (about-ish; S3 Standard @ $0.023/GB/mo, no cross-region replication):' || chr(10)
      || 'Currently stored: ' || stored_gb_s || ' GB  ~' || stored_cost_now_s || '/mo today' || chr(10)
      || 'Growing ~' || total_gb_s || ' GB/mo, and storage is cumulative.' || chr(10)
      || 'Projected next 12 months of S3 spend: ' || proj_12mo_s || chr(10)
      || 'Forecast factor: multiply monthly-added GB by the month number (cumulative), '
      || 'then apply ~1.2x for request/overhead. No replication multiplier needed.'
    AS fact
FROM pretty

ORDER BY ord;
