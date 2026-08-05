/*
Funding Agreement Requirement:
"The total volume of data submitted is expected to remain consistent month to
month. For purposes of performance monitoring, each QE will be required to
submit, at a minimum the aggregate amount of data; NYeC will assess this using
a rolling two-month average of submitted volume, by data type, as the
'baseline.' Beginning June 15th (and monthly thereafter), NYeC will inform
each QE of its baseline. If, for a full calendar month, a QE's submitted
volume is more than 10% below its baseline, and the variance is not
attributable to expected changes (e.g., participant onboarding/offboarding or
other agreed-upon adjustments), the variance will be considered a PDR outage."

Goal:
- Monthly document count by QE and data type (CCD, TRN, ORU).
- Excludes backload data — only real-time/normal submissions.
- Shows BOTH:
    1. Raw monthly volume (doc_count)
    2. Rolling 2-month average baseline (rolling_2mo_avg)
- Also shows:
    - pct_of_baseline: current month as a % of the rolling baseline
    - below_10pct_flag: 'YES' if volume is more than 10% below baseline

How to use:
- Set start_month and end_month in config.
- start_month should be at least 2 months before the period you want to assess
  (so the rolling average has data to work from).
- Each row = one QE + data type + month.

Expected cost/run: Scales with months selected. ~$0.50/month of data (~100 GB/month).
*/

WITH config AS (
    SELECT
        DATE '2026-01-01' AS start_month,       -- << first day of first month (include 2+ months before assessment period)
        DATE '2026-07-01' AS end_month,         -- << first day of last month to include
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
),

-- Raw monthly counts
monthly_raw AS (
    SELECT
        date_format(md.month_start, '%Y-%m') AS month,
        md.month_start,
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
),

-- Add rolling 2-month average (baseline = average of prior 2 months)
with_baseline AS (
    SELECT
        month,
        qe,
        data_type,
        doc_count,
        CAST(round(avg(doc_count) OVER (
            PARTITION BY qe, data_type
            ORDER BY month_start
            ROWS BETWEEN 2 PRECEDING AND 1 PRECEDING
        )) AS bigint) AS rolling_2mo_avg
    FROM monthly_raw
)

SELECT
    month,
    qe,
    data_type,
    doc_count,
    rolling_2mo_avg,
    CASE
        WHEN rolling_2mo_avg IS NULL OR rolling_2mo_avg = 0 THEN NULL
        ELSE CAST(round(100.0 * doc_count / rolling_2mo_avg) AS bigint)
    END AS pct_of_baseline,
    CASE
        WHEN rolling_2mo_avg IS NULL OR rolling_2mo_avg = 0 THEN 'N/A'
        WHEN doc_count < (rolling_2mo_avg * 0.9) THEN 'YES'
        ELSE 'NO'
    END AS below_10pct_flag
FROM with_baseline
ORDER BY qe ASC, data_type ASC, month ASC;
