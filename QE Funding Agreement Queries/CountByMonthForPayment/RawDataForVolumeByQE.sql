/*
Why this query exists:
- The funding agreement requires QEs to maintain consistent monthly submission
  volume. A rolling 2-month average is used as the baseline, and any month that
  drops more than 10% below baseline (without agreed-upon justification) is
  considered a PDR outage.
- This query provides the DAY-LEVEL detail behind the monthly totals so you can:
    1. Show your work — every day's contribution to the monthly total is visible.
    2. Bring into Excel and pivot/filter to investigate drops.
    3. Identify exactly which days drove a shortfall.
- Excludes backload data (only real-time/normal submissions count toward the goal).

How to use:
- Set start_month and end_month in config.
- Export results to CSV, open in Excel.
- Pivot: Rows = day, Columns = qe, Values = sum of doc_count.
- Or filter by qe and data_type to drill into a specific concern.
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
    date_format(md.target_day, '%Y-%m-%d') AS day,
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
GROUP BY 1, 2, 3, 4
ORDER BY qe ASC, data_type ASC, day ASC;
