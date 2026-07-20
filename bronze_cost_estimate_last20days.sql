/*
Goal:
- Estimate RAW -> Bronze (Parquet in S3) processing/storage cost inputs for all data.
- Return the last 20 complete days of document metrics by document type.

What this returns (per 20-day window, per doc_type):
- total_documents
- avg_document_size_bytes
- avg_document_size_mb

Also returns (per doc_type) annualized projections based on the same 20-day window:
- projected_annual_documents

Notes:
- Excludes today (uses the last 20 complete days).
- Includes TRN, CCD, ORU document types.
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
        p.target_day AS day,
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
)
SELECT
    'TOTAL_20_DAY_WINDOW' AS section,
    CAST(NULL AS date) AS day,
    doc_type,
    format('%,d', count(*)) AS total_documents,
    CAST(round(avg(CAST(doc_size_bytes AS double)), 0) AS bigint) AS avg_document_size_bytes,
    round(avg(CAST(doc_size_bytes AS double)) / pow(1024, 2), 2) AS avg_document_size_mb
FROM typed
WHERE doc_type IS NOT NULL
GROUP BY 3

UNION ALL

SELECT
    'ANNUALIZED_FROM_20_DAY_WINDOW' AS section,
    CAST(NULL AS date) AS day,
    doc_type,
    format('%,d', CAST((count(*) / 20.0) * 365 AS bigint)) AS total_documents,
    CAST(round(avg(CAST(doc_size_bytes AS double)), 0) AS bigint) AS avg_document_size_bytes,
    round(avg(CAST(doc_size_bytes AS double)) / pow(1024, 2), 2) AS avg_document_size_mb
FROM typed
WHERE doc_type IS NOT NULL
GROUP BY 3

ORDER BY section, day, doc_type;
