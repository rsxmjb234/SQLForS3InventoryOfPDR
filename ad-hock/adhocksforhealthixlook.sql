/*
Expected cost/run (6 months): ~$1.94 (387 GB scanned @ $5/TB)
Expected runtime: ~2.5 minutes

Why this query exists:
- Compares document SIZE characteristics across QEs on a weekly basis.
- The goal is to identify whether Healthix (or any QE) is submitting documents
  that are anomalously small — which could indicate invalid/empty documents
  (e.g., CCD shells with no clinical content, or stub TRNs).
- Only looks at BACKLOG data.
- If Healthix's average doc size is dramatically smaller than other QEs for the
  same data type, that's a red flag worth investigating.

What to look for in results:
- Compare avg_size_kb and median_size_kb across QEs for the same data_type/week.
- If one QE's average is 1-2 KB while others are 50-200 KB, those docs may be
  invalid stubs.
- Also look at pct_under_1kb — a high percentage of tiny docs is suspicious.

How to use:
- Set start_month and end_month in config.
- Results are weekly, grouped by QE and data type.
- Export to Excel, filter by data_type, compare QEs side by side.
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
),

raw_docs AS (
    SELECT
        date_format(date_trunc('week', md.target_day), '%Y-%m-%d') AS week_start,
        regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS qe,
        CASE
            WHEN regexp_like(lower(i.key), '(^|/)ccd(/|$)') THEN 'CCD'
            WHEN regexp_like(lower(i.key), '(^|/)trn(/|$)') THEN 'TRN'
            WHEN regexp_like(lower(i.key), '(^|/)oru(/|$)') THEN 'ORU'
        END AS data_type,
        i.size AS size_bytes
    FROM pdr_inventory.pdr_inventory_prod_data_all i
    JOIN month_days md
        ON i.dt = md.dt_target_partition
        AND i.last_modified_date >= CAST(md.target_day AS timestamp)
        AND i.last_modified_date < CAST(date_add('day', 1, md.target_day) AS timestamp)
    WHERE
        i.bucket LIKE 'nyec-pdr-prod-%'
        AND i.is_latest = true
        AND coalesce(i.is_delete_marker, false) = false
        AND regexp_like(lower(i.key), '(^|/)backload/')
        AND (
            regexp_like(lower(i.key), '(^|/)ccd(/|$)')
            OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
            OR regexp_like(lower(i.key), '(^|/)oru(/|$)')
        )
)

SELECT
    week_start,
    qe,
    data_type,
    count(*)                                                    AS doc_count,
    round(avg(size_bytes) / 1024.0, 1)                          AS avg_size_kb,
    round(approx_percentile(size_bytes, 0.5) / 1024.0, 1)      AS median_size_kb,
    round(min(size_bytes) / 1024.0, 1)                          AS min_size_kb,
    round(approx_percentile(size_bytes, 0.25) / 1024.0, 1)     AS p25_size_kb,
    round(approx_percentile(size_bytes, 0.75) / 1024.0, 1)     AS p75_size_kb,
    round(max(size_bytes) / 1024.0, 1)                          AS max_size_kb,
    round(100.0 * count_if(size_bytes < 1024) / count(*), 1)    AS pct_under_1kb,
    round(100.0 * count_if(size_bytes < 5120) / count(*), 1)    AS pct_under_5kb
FROM raw_docs
WHERE data_type IS NOT NULL
GROUP BY 1, 2, 3
ORDER BY data_type ASC, week_start ASC, avg_size_kb ASC;
