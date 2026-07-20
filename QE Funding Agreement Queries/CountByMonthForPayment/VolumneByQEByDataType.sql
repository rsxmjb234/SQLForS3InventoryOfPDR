/*
Goal:
- Monthly document count by QE and data type (CCD, TRN, ORU).
- Excludes backload data — only real-time/normal submissions.
- Used to assess whether a QE's monthly volume is within 10% of its
  rolling 2-month baseline (per the funding agreement).

How to use:
- Set start_month and end_month in config.
- Each row = one QE + data type + month.

Expected cost/run: Scales with months selected. ~$0.50/month of data (~100 GB/month).
*/

WITH config AS (
    SELECT
        DATE '2026-01-01' AS start_month,       -- << first day of first month
        DATE '2026-06-01' AS end_month,         -- << first day of last month to include
        2 AS inventory_snapshot_offset_days
),
months AS (
    SELECT
        m AS month_start,
        date_add('month', 1, m) AS month_end
    FROM config c
    CROSS JOIN UNNEST(sequence(c.start_month, c.end_month, INTERVAL '1' MONTH)) AS t(m)
),
-- For each month, generate every day so we can map to inventory partitions
month_days AS (
    SELECT
        m.month_start,
        d AS target_day,
        date_format(
            date_add('day', c.inventory_snapshot_offset_days, d),
            '%Y-%m-%d-01-00'
        ) AS dt_target_partition
    FROM months m
    CROSS JOIN config c
    CROSS JOIN UNNEST(sequence(m.month_start, date_add('day', -1, m.month_end), INTERVAL '1' DAY)) AS t(d)
)

SELECT
    date_format(md.month_start, '%Y-%m') AS month,
    regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS qe,
    CASE
        WHEN regexp_like(lower(i.key), '(^|/)ccd(/|$)') THEN 'CCD'
        WHEN regexp_like(lower(i.key), '(^|/)trn(/|$)') THEN 'TRN'
        WHEN regexp_like(lower(i.key), '(^|/)oru(/|$)') THEN 'ORU'
    END AS data_type,
    count(*) AS doc_count
FROM pdr_inventory.pdr_inventory_prod_data_all i
JOIN month_days md
    ON i.dt = md.dt_target_partition
    AND i.last_modified_date >= CAST(md.target_day AS timestamp)
    AND i.last_modified_date < CAST(date_add('day', 1, md.target_day) AS timestamp)
WHERE
    i.bucket LIKE 'nyec-pdr-prod-%'
    AND i.is_latest = true
    AND coalesce(i.is_delete_marker, false) = false
    -- Exclude backload
    AND NOT regexp_like(lower(i.key), '(^|/)backload/')
    -- Only known doc types
    AND (
        regexp_like(lower(i.key), '(^|/)ccd(/|$)')
        OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
        OR regexp_like(lower(i.key), '(^|/)oru(/|$)')
    )
GROUP BY 1, 2, 3
ORDER BY qe ASC, data_type ASC, month ASC;
