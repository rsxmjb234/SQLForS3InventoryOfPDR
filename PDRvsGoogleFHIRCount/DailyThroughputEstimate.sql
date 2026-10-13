/*
Expected cost/run: ~$0.12 (two single-day snapshots, metadata columns only)
Expected runtime: ~1 minute

Goal (LOW PRIORITY — rough "how big is this system" sizing):
- Estimate the average DAILY throughput of the PDR for CCD and TRN.
- Method: take two cumulative snapshots N days apart, subtract, divide by N.
  (growth in total documents) / (days between snapshots) = docs added per day.
- Excludes backlog; applies the 2026-03-11 clinical-data floor; counts ALL
  sources (orphans included) so this is total system intake.

Why two snapshots instead of a daily count:
- Each inventory dt partition is a full snapshot. Comparing the standing total
  at two points and dividing by elapsed days gives a clean average intake rate
  that is not distorted by any single day's timing.

Config:
- recent_day  = the newer snapshot (default: 4 days ago, known complete)
- days_back   = how far back the older snapshot sits from recent_day
*/

WITH config AS (
    SELECT
        4   AS recent_lag_days,             -- newer snapshot = today - 4
        60  AS days_back,                   -- older snapshot = recent - 60 days
        2   AS inventory_snapshot_offset_days
),
anchors AS (
    SELECT
        date_add('day', -recent_lag_days, current_date)              AS recent_day,
        date_add('day', -(recent_lag_days + days_back), current_date) AS older_day,
        days_back,
        inventory_snapshot_offset_days
    FROM config
),
parts AS (
    SELECT
        recent_day,
        older_day,
        days_back,
        date_format(date_add('day', inventory_snapshot_offset_days, recent_day), '%Y-%m-%d-01-00') AS recent_dt,
        date_format(date_add('day', inventory_snapshot_offset_days, older_day),  '%Y-%m-%d-01-00') AS older_dt
    FROM anchors
),

-- Count the full standing population in each of the two snapshots
snap_counts AS (
    SELECT
        CASE WHEN i.dt = p.recent_dt THEN 'recent' ELSE 'older' END AS which_snap,
        count_if(regexp_like(lower(i.key), '(^|/)ccd(/|$)')) AS ccd,
        count_if(regexp_like(lower(i.key), '(^|/)trn(/|$)')) AS trn
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
        )
    GROUP BY 1
)

SELECT
    (SELECT date_format(older_day,  '%Y-%m-%d') FROM anchors) AS older_snapshot,
    (SELECT date_format(recent_day, '%Y-%m-%d') FROM anchors) AS recent_snapshot,
    (SELECT days_back FROM anchors) AS days_between,
    r.ccd AS recent_ccd_total,
    o.ccd AS older_ccd_total,
    r.trn AS recent_trn_total,
    o.trn AS older_trn_total,
    CAST(round((r.ccd - o.ccd) / CAST((SELECT days_back FROM anchors) AS double)) AS bigint) AS ccd_per_day,
    CAST(round((r.trn - o.trn) / CAST((SELECT days_back FROM anchors) AS double)) AS bigint) AS trn_per_day
FROM
    (SELECT ccd, trn FROM snap_counts WHERE which_snap = 'recent') r
CROSS JOIN
    (SELECT ccd, trn FROM snap_counts WHERE which_snap = 'older') o;
