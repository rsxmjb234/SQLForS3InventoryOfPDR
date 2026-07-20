/*
Goal:
- Provide a quote-ready annualized breakout for TRN and CCD by percentile threshold.
- For each percentile (5, 25, 50, 75, 99), show:
  1) expected annual document count at or below that threshold
  2) the threshold size in bytes and MB

This format makes statements like:
"Annually we get N CCDs that are smaller than X MB (5th percentile)."
*/

WITH config AS (
    SELECT
    date_add('day', -20, date(current_timestamp AT TIME ZONE 'America/New_York')) AS start_day,
    date_add('day', -1, date(current_timestamp AT TIME ZONE 'America/New_York')) AS end_day,
        2 AS inventory_snapshot_offset_days
),
days AS (
    SELECT
        d AS target_day
    FROM config c
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
    CROSS JOIN config c
),
typed AS (
    SELECT
        CASE
            WHEN regexp_like(lower(i.key), '(^|/)trn(/|$)') THEN 'TRN'
            WHEN regexp_like(lower(i.key), '(^|/)ccd(/|$)') THEN 'CCD'
            WHEN regexp_like(lower(i.key), '(^|/)oru(/|$)') THEN 'ORU'
        END AS doc_type,
        CAST(i.size AS double) AS doc_size_bytes
    FROM pdr_inventory.pdr_inventory_prod_data_all i
    JOIN params p
        ON i.dt = p.dt_target_partition
        AND i.last_modified_date >= p.day_start_ts
        AND i.last_modified_date < p.day_end_ts
    WHERE
        i.bucket LIKE 'nyec-pdr-prod-%'
        AND i.is_latest = true
        AND coalesce(i.is_delete_marker, false) = false
        AND i.size IS NOT NULL
        AND (
            regexp_like(lower(i.key), '(^|/)trn(/|$)')
            OR regexp_like(lower(i.key), '(^|/)ccd(/|$)')
            OR regexp_like(lower(i.key), '(^|/)oru(/|$)')
        )
),
filtered AS (
    SELECT
        doc_type,
        doc_size_bytes
    FROM typed
    WHERE doc_type IN ('TRN', 'CCD')
),
summary AS (
    SELECT
        doc_type,
        (count(*) / 20.0) * 365 AS annual_docs_est,
        approx_percentile(doc_size_bytes, 0.05) AS p05_size_bytes,
        approx_percentile(doc_size_bytes, 0.25) AS p25_size_bytes,
        approx_percentile(doc_size_bytes, 0.50) AS p50_size_bytes,
        approx_percentile(doc_size_bytes, 0.75) AS p75_size_bytes,
        approx_percentile(doc_size_bytes, 0.99) AS p99_size_bytes
    FROM filtered
    GROUP BY 1
),
expanded AS (
    SELECT
        doc_type,
        0.05 AS percentile_rank,
        'p05' AS percentile_label,
        annual_docs_est * 0.05 AS annual_docs_at_or_below,
        p05_size_bytes AS threshold_size_bytes
    FROM summary

    UNION ALL

    SELECT
        doc_type,
        0.25 AS percentile_rank,
        'p25' AS percentile_label,
        annual_docs_est * 0.25 AS annual_docs_at_or_below,
        p25_size_bytes AS threshold_size_bytes
    FROM summary

    UNION ALL

    SELECT
        doc_type,
        0.50 AS percentile_rank,
        'p50' AS percentile_label,
        annual_docs_est * 0.50 AS annual_docs_at_or_below,
        p50_size_bytes AS threshold_size_bytes
    FROM summary

    UNION ALL

    SELECT
        doc_type,
        0.75 AS percentile_rank,
        'p75' AS percentile_label,
        annual_docs_est * 0.75 AS annual_docs_at_or_below,
        p75_size_bytes AS threshold_size_bytes
    FROM summary

    UNION ALL

    SELECT
        doc_type,
        0.99 AS percentile_rank,
        'p99' AS percentile_label,
        annual_docs_est * 0.99 AS annual_docs_at_or_below,
        p99_size_bytes AS threshold_size_bytes
    FROM summary
)
SELECT
    doc_type,
    percentile_label,
    CAST(percentile_rank * 100 AS integer) AS percentile,
    format('%,d', CAST(round(annual_docs_at_or_below, 0) AS bigint)) AS annual_docs_at_or_below_est,
    CAST(round(threshold_size_bytes, 0) AS bigint) AS threshold_size_bytes,
    round(threshold_size_bytes / pow(1024, 2), 4) AS threshold_size_mb,
    format(
        'Annually we get %,d %s documents smaller than %.4f MB (<= %s threshold).',
        CAST(round(annual_docs_at_or_below, 0) AS bigint),
        doc_type,
        round(threshold_size_bytes / pow(1024, 2), 4),
        percentile_label
    ) AS narrative
FROM expanded
ORDER BY doc_type, percentile_rank;
