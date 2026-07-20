/*
Goal:
- Daily backlog submission counts by QE, broken out by CCD and TRN.
- One row per QE per day — easy to pivot in Excel for charting.
- 30-day window (configurable).

Expected cost/run: ~$1.40 (scans ~280 GB for 30 days @ $5/TB)
Expected runtime: ~3 minutes

Excel tip: Paste into Excel, insert a Pivot Table.
  Rows = day, Columns = qe, Values = ccd_count (or trn_count).
  Then insert a line chart from the pivot.
  goes here: https://nyehealth.sharepoint.com/:x:/s/Extranet-PrimaryDocumentRepository/IQAkKVdbwKIAT6N7KN1FbTXlAeCJkBiIHqhDX6Qza1l-Z-4?e=OAlq1d
*/

WITH config AS (
    SELECT
        DATE '2026-07-16' AS start_day,                     -- << CHANGE THIS: first day you need
        date_add('day', -1, current_date) AS end_day,       -- today in UTC minus 2; inventory partition is reliable
        2  AS inventory_snapshot_offset_days
),
date_range AS (
    SELECT
        c.start_day,
        c.end_day,
        c.inventory_snapshot_offset_days
    FROM config c
),
days AS (
    SELECT
        d AS target_day
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
)

SELECT
    date_format(p.target_day, '%Y-%m-%d') AS day,
    regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS qe,
    count_if(regexp_like(lower(i.key), '(^|/)ccd(/|$)')) AS ccd_count,
    count_if(regexp_like(lower(i.key), '(^|/)trn(/|$)')) AS trn_count
FROM pdr_inventory.pdr_inventory_prod_data_all i
JOIN params p
    ON i.dt = p.dt_target_partition
    AND i.last_modified_date >= p.day_start_ts
    AND i.last_modified_date < p.day_end_ts
WHERE
    i.bucket LIKE 'nyec-pdr-prod-%'
    AND i.is_latest = true
    AND coalesce(i.is_delete_marker, false) = false
    AND regexp_like(lower(i.key), '(^|/)backload/')
    AND (
        regexp_like(lower(i.key), '(^|/)ccd(/|$)')
        OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
    )
GROUP BY 1, 2
ORDER BY day ASC, qe DESC;
