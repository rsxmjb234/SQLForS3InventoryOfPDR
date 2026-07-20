/*
Goal:
- Estimate annual TRN and CCD document volume and size profile from the last 20 complete days.
- Show expected annual document counts and size thresholds at p05, p25, p50, p75, p99.
- Show annualized counts in size bands where size is >= each percentile cutoff and < the next cutoff.

What this returns (one row per doc_type: TRN, CCD):
- annual_total_documents_est
- annual_docs_lt_p05_est
- annual_docs_gte_p05_lt_p25_est
- annual_docs_gte_p25_lt_p50_est
- annual_docs_gte_p50_lt_p75_est
- annual_docs_gte_p75_lt_p99_est
- annual_docs_gte_p99_est
- p05_size_bytes / p05_size_mb ("what is small")
- p25_size_bytes / p25_size_mb
- p50_size_bytes / p50_size_mb
- p75_size_bytes / p75_size_mb
- p99_size_bytes / p99_size_mb

Notes:
- Excludes today (uses the last 20 complete days).
- Uses the same inventory snapshot offset logic as the bronze cost estimate query.
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
        i.size AS doc_size_bytes
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
        CAST(doc_size_bytes AS double) AS doc_size_bytes
    FROM typed
    WHERE doc_type IN ('TRN', 'CCD')
),
summary AS (
    SELECT
        doc_type,
        count(*) AS docs_20d,
        approx_percentile(doc_size_bytes, 0.05) AS p05_size_bytes,
        approx_percentile(doc_size_bytes, 0.25) AS p25_size_bytes,
        approx_percentile(doc_size_bytes, 0.50) AS p50_size_bytes,
        approx_percentile(doc_size_bytes, 0.75) AS p75_size_bytes,
        approx_percentile(doc_size_bytes, 0.99) AS p99_size_bytes
    FROM filtered
    GROUP BY 1
),
band_counts AS (
    SELECT
        f.doc_type,
        s.docs_20d,
        sum(CASE WHEN f.doc_size_bytes < s.p05_size_bytes THEN 1 ELSE 0 END) AS docs_lt_p05_20d,
        sum(CASE WHEN f.doc_size_bytes >= s.p05_size_bytes AND f.doc_size_bytes < s.p25_size_bytes THEN 1 ELSE 0 END) AS docs_gte_p05_lt_p25_20d,
        sum(CASE WHEN f.doc_size_bytes >= s.p25_size_bytes AND f.doc_size_bytes < s.p50_size_bytes THEN 1 ELSE 0 END) AS docs_gte_p25_lt_p50_20d,
        sum(CASE WHEN f.doc_size_bytes >= s.p50_size_bytes AND f.doc_size_bytes < s.p75_size_bytes THEN 1 ELSE 0 END) AS docs_gte_p50_lt_p75_20d,
        sum(CASE WHEN f.doc_size_bytes >= s.p75_size_bytes AND f.doc_size_bytes < s.p99_size_bytes THEN 1 ELSE 0 END) AS docs_gte_p75_lt_p99_20d,
        sum(CASE WHEN f.doc_size_bytes >= s.p99_size_bytes THEN 1 ELSE 0 END) AS docs_gte_p99_20d
    FROM filtered f
    JOIN summary s
        ON f.doc_type = s.doc_type
    GROUP BY 1, 2
)
SELECT
    s.doc_type,
    format('%,d', CAST(round((b.docs_20d / 20.0) * 365, 0) AS bigint)) AS annual_total_documents_est,
    format('%,d', CAST(round((b.docs_lt_p05_20d / 20.0) * 365, 0) AS bigint)) AS annual_docs_lt_p05_est,
    format('%,d', CAST(round((b.docs_gte_p05_lt_p25_20d / 20.0) * 365, 0) AS bigint)) AS annual_docs_gte_p05_lt_p25_est,
    format('%,d', CAST(round((b.docs_gte_p25_lt_p50_20d / 20.0) * 365, 0) AS bigint)) AS annual_docs_gte_p25_lt_p50_est,
    format('%,d', CAST(round((b.docs_gte_p50_lt_p75_20d / 20.0) * 365, 0) AS bigint)) AS annual_docs_gte_p50_lt_p75_est,
    format('%,d', CAST(round((b.docs_gte_p75_lt_p99_20d / 20.0) * 365, 0) AS bigint)) AS annual_docs_gte_p75_lt_p99_est,
    format('%,d', CAST(round((b.docs_gte_p99_20d / 20.0) * 365, 0) AS bigint)) AS annual_docs_gte_p99_est,
    CAST(round(s.p05_size_bytes, 0) AS bigint) AS p05_size_bytes,
    round(s.p05_size_bytes / pow(1024, 2), 2) AS p05_size_mb,
    CAST(round(s.p25_size_bytes, 0) AS bigint) AS p25_size_bytes,
    round(s.p25_size_bytes / pow(1024, 2), 2) AS p25_size_mb,
    CAST(round(s.p50_size_bytes, 0) AS bigint) AS p50_size_bytes,
    round(s.p50_size_bytes / pow(1024, 2), 2) AS p50_size_mb,
    CAST(round(s.p75_size_bytes, 0) AS bigint) AS p75_size_bytes,
    round(s.p75_size_bytes / pow(1024, 2), 2) AS p75_size_mb,
    CAST(round(s.p99_size_bytes, 0) AS bigint) AS p99_size_bytes,
    round(s.p99_size_bytes / pow(1024, 2), 2) AS p99_size_mb
FROM summary s
JOIN band_counts b
    ON s.doc_type = b.doc_type
ORDER BY s.doc_type;
