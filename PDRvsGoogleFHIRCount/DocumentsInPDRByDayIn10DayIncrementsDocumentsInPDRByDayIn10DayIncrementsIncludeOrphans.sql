/*
Expected cost/run: ~$0.85 (samples ~10 inventory days — every 10th day over 100, ~171 GB)
Expected runtime: ~8-11 minutes

Goal:
- Count the CUMULATIVE TOTAL of PDR documents (CCD and TRN) by QE, as of each
  inventory snapshot, sampling every 10 days over the last 100 days.
- This is the TOTAL documents in the system on that snapshot date (full
  snapshot population), NOT documents added that day.
- ALL SOURCES — this version does NOT exclude anything. (Companion to
  PDRvsGoogleFHIRCount.sql, which excludes sources not in the Verato MPI.)

How the snapshot is read:
- S3 Inventory is a full snapshot: each dt partition lists every object in the
  bucket at that time. We count the WHOLE snapshot (no last_modified_date day
  window), so the number reflects the running total — it should trend upward
  over time, not bounce up and down day to day.
- EXCLUDE any document dated before 2026-03-11. PDR data contributed before
  that date was only the HEADER information, not the clinical document, so it
  must not be counted (filtered via last_modified_date in the query body).

Output: date, qe, ccd, trn
*/

WITH config AS (
    SELECT
        100 AS lookback_days,               -- << total span to cover
        10  AS sample_every_days,           -- << sample 1 day out of every N
        3   AS inventory_lag_days,
        2   AS inventory_snapshot_offset_days
),
date_range AS (
    SELECT
        date_add('day', -(c.lookback_days + c.inventory_lag_days - 1), current_date) AS start_day,
        date_add('day', -c.inventory_lag_days, current_date) AS end_day,
        c.sample_every_days,
        c.inventory_snapshot_offset_days
    FROM config c
),
-- Sample every Nth day across the span
days AS (
    SELECT
        d AS target_day
    FROM date_range c
    CROSS JOIN UNNEST(
        sequence(c.start_day, c.end_day, INTERVAL '1' DAY * c.sample_every_days)
    ) AS t(d)
),
params AS (
    SELECT
        d.target_day,
        date_format(
            date_add('day', c.inventory_snapshot_offset_days, d.target_day),
            '%Y-%m-%d-01-00'
        ) AS dt_target_partition
    FROM days d
    CROSS JOIN date_range c
)

SELECT
    date_format(p.target_day, '%Y-%m-%d') AS date,
    regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS qe,
    count_if(regexp_like(lower(i.key), '(^|/)ccd(/|$)')) AS ccd,
    count_if(regexp_like(lower(i.key), '(^|/)trn(/|$)')) AS trn
FROM pdr_inventory.pdr_inventory_prod_data_all i
JOIN params p
    ON i.dt = p.dt_target_partition
WHERE
    i.bucket LIKE 'nyec-pdr-prod-%'
    AND i.is_latest = true
    AND coalesce(i.is_delete_marker, false) = false
    -- PDR data contributed before 2026-03-11 was only the HEADER information, not the clinical document; exclude it.
    AND i.last_modified_date >= timestamp '2026-03-11 00:00:00'
    AND NOT regexp_like(lower(i.key), '(^|/)backload(/|$)')
    AND (
        regexp_like(lower(i.key), '(^|/)ccd(/|$)')
        OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
    )
GROUP BY 1, 2
ORDER BY date ASC, qe ASC;
