/*
Expected cost/run: ~$0.06 (single inventory day, ~12 GB @ $5/TB)
Expected runtime: ~30 seconds

Goal:
- Find "orphan" sources — assigning authorities that are actively submitting
  data to the PDR but do NOT exist in the Verato MPI (lookup_verato_aa table).
- These are sources contributing clinical documents (CCD/TRN) that have no
  corresponding patient identity linkage in the MPI. This means their data
  lands in PDR but may not be matchable to patients, effectively making it
  unreachable for care coordination.
- Identifying orphans helps prioritize onboarding them into the MPI.

CURRENT STATE ONLY:
- This looks at a SINGLE inventory day (3 days ago), not a rolling history.
- We only care about data landing in PDR NOW that lacks an MPI entry.
- Over time the team moves/fixes files, so a source that was orphaned weeks ago
  may already be resolved. Looking at one recent day avoids flagging those.

How it works:
1. Pulls ONE day of real-time PDR inventory data (3 days ago; excludes backlog).
2. Maps QE bucket names to the naming convention used in lookup_verato_aa.
3. LEFT JOINs against lookup_verato_aa — any source with no match is an orphan.
4. Returns QE, assigning_authority, CCD count, TRN count for each current orphan.

Rules:
- Verato assigning_authority values may have suffixes like .DUPLICATE,
  .DUPLICATE1, .DUPLICATE2, .DUPLICATE3 — these are stripped before comparing
  so that a PDR source with AA "HOSPITAL-A" matches a Verato entry
  "HOSPITAL-A.DUPLICATE" and is NOT flagged as an orphan.
- For QE=BRONX only: underscores (_) in Verato AA are treated as spaces
  when comparing to PDR AA (e.g., Verato "BRONX_LEBANON" matches PDR "BRONX LEBANON").

QE name mapping (PDR bucket name → Verato table name):
    bronx              → BRONX
    rochester          → GRRHIO
    healtheconnections → HECDCS
    healthix           → HEALTHIX
    hixny              → HIXNY
    techbd             → TXD
    healthelink        → HEALTHELINK
*/

WITH config AS (
    SELECT
        3  AS inventory_lag_days,            -- single day = 3 days ago (current state)
        2  AS inventory_snapshot_offset_days
),
-- Single target day = 3 days ago (current state, not a rolling history)
params AS (
    SELECT
        date_add('day', -c.inventory_lag_days, current_date) AS target_day,
        CAST(date_add('day', -c.inventory_lag_days, current_date) AS timestamp) AS day_start_ts,
        CAST(date_add('day', -(c.inventory_lag_days - 1), current_date) AS timestamp) AS day_end_ts,
        date_format(
            date_add('day', c.inventory_snapshot_offset_days,
                     date_add('day', -c.inventory_lag_days, current_date)),
            '%Y-%m-%d-01-00'
        ) AS dt_target_partition
    FROM config c
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

-- Get all active sources from PDR inventory (real-time only, no backlog)
pdr_sources AS (
    SELECT
        regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS qe,
        upper(trim(
            CASE
                WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error', 'backload')
                THEN split_part(i.key, '/', 2)
                ELSE split_part(i.key, '/', 1)
            END
        )) AS assigning_authority,
        CASE
            WHEN regexp_like(lower(i.key), '(^|/)ccd(/|$)') THEN 'CCD'
            WHEN regexp_like(lower(i.key), '(^|/)trn(/|$)') THEN 'TRN'
        END AS data_type,
        i.last_modified_date
    FROM pdr_inventory.pdr_inventory_prod_data_all i
    JOIN params p
        ON i.dt = p.dt_target_partition
        AND i.last_modified_date >= p.day_start_ts
        AND i.last_modified_date < p.day_end_ts
    WHERE
        i.bucket LIKE 'nyec-pdr-prod-%'
        AND i.is_latest = true
        AND coalesce(i.is_delete_marker, false) = false
        AND NOT regexp_like(lower(i.key), '(^|/)backload(/|$)')
        AND (
            regexp_like(lower(i.key), '(^|/)ccd(/|$)')
            OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
        )
),

-- Aggregate by QE + AA
pdr_summary AS (
    SELECT
        qe,
        assigning_authority,
        count_if(data_type = 'CCD') AS ccd_count,
        count_if(data_type = 'TRN') AS trn_count,
        max(last_modified_date) AS most_recent_submission
    FROM pdr_sources
    WHERE assigning_authority IS NOT NULL
      AND assigning_authority <> ''
    GROUP BY 1, 2
),

-- Map QE names and join to Verato to find orphans
orphans AS (
    SELECT
        p.qe,
        p.assigning_authority,
        p.ccd_count,
        p.trn_count,
        p.most_recent_submission,
        m.verato_name
    FROM pdr_summary p
    LEFT JOIN qe_name_map m
        ON lower(p.qe) = lower(m.pdr_name)
    LEFT JOIN pdr_inventory.lookup_verato_aa v
        ON upper(v.qe) = upper(m.verato_name)
        AND upper(regexp_replace(regexp_replace(v.assigning_authority,
            '\.(DUPLICATE|DUPLICATE1|DUPLICATE2|DUPLICATE3)$', ''),
            CASE WHEN upper(m.verato_name) = 'BRONX' THEN '_' ELSE '' END,
            CASE WHEN upper(m.verato_name) = 'BRONX' THEN ' ' ELSE '' END
        )) = upper(p.assigning_authority)
    WHERE v.assigning_authority IS NULL
)

SELECT
    qe,
    assigning_authority AS assigning_authority_PDR,
    ccd_count,
    trn_count,
    ccd_count + trn_count AS total_docs,
    date_format(most_recent_submission, '%Y-%m-%d %H:%i:%s') AS most_recent_submission
FROM orphans
ORDER BY qe ASC, ccd_count DESC;
