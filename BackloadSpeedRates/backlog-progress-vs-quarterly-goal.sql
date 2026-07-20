/*
Goal:
- Compare each QE's actual backlog submissions this quarter against their
  quarterly target (docs per day from the funding agreement).
- Based on 10-day rolling average of backlog submissions vs daily target.
- The quarterly targets are based on June 2026 averages per the agreement:
    HEALTHIX         277,000 / day
    HEALTHECONNECTIONS 253,000 / day
    ROCHESTER        150,000 / day
    TECHBD           116,000 / day
    BRONX             57,000 / day
    HIXNY             50,000 / day

Expected cost/run: ~$0.59 (118 GB scanned @ $5/TB for ~10 days)
Expected runtime: ~1 minute

Output:
- One row per QE with a plain-English statement for leadership.

How to use:
- Set quarter_start to the first day of the current quarter.
- Update daily targets if they change.
- Run and read the summary column for a quick status.
*/

WITH config AS (
    SELECT
        DATE '2026-07-14' AS start_day,         -- << CHANGE THIS: first day of data you need
        DATE '2026-07-18' AS end_day,           -- << CHANGE THIS: last reliable day (today - 2 with offset 2)
        2  AS inventory_snapshot_offset_days
),

-- Quarterly daily targets per QE (docs/day from funding agreement)
targets AS (
    SELECT qe, daily_target
    FROM (VALUES
        ('healthix',           277000),
        ('healtheconnections', 253000),
        ('rochester',          150000),
        ('techbd',             116000),
        ('bronx',               57000),
        ('hixny',               50000)
    ) AS t(qe, daily_target)
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
),

-- Count backlog docs per QE per day
daily_backlog AS (
    SELECT
        date_format(p.target_day, '%Y-%m-%d') AS day,
        regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS qe,
        count(*) AS doc_count
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
),

-- Summarize per QE
qe_summary AS (
    SELECT
        d.qe,
        t.daily_target,
        count(DISTINCT day) AS days_with_data,
        sum(doc_count) AS total_docs_submitted,
        round(CAST(sum(doc_count) AS double) / count(DISTINCT day)) AS actual_avg_per_day
    FROM daily_backlog d
    INNER JOIN targets t ON lower(d.qe) = lower(t.qe)
    GROUP BY d.qe, t.daily_target
)

SELECT
    upper(s.qe) || ' is averaging '
        || CAST(CAST(round(s.actual_avg_per_day / 1000.0) AS bigint) AS varchar) || 'K docs/day'
        || ' which is '
        || CASE
            WHEN s.actual_avg_per_day >= s.daily_target
            THEN CAST(CAST(round(100.0 * (s.actual_avg_per_day - s.daily_target) / s.daily_target) AS bigint) AS varchar) || '% ahead of'
            ELSE CAST(CAST(round(100.0 * (s.daily_target - s.actual_avg_per_day) / s.daily_target) AS bigint) AS varchar) || '% behind'
        END
        || ' their ' || CAST(CAST(round(s.daily_target / 1000.0) AS bigint) AS varchar) || 'K/day target.'
    AS status
FROM qe_summary s
ORDER BY actual_avg_per_day DESC;
