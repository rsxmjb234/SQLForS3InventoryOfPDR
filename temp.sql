/*
Goal:
- Average document size for TRN, CCD, and ORU (labs) over the last 20 complete days.

Notes:
- Excludes today (uses the last 20 complete days).
- Uses the same inventory snapshot offset logic as the other PDR size queries.
- "labs" = 'lab' key path segment (per rules.md — NOT 'oru').
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
            WHEN regexp_like(lower(i.key), '(^|/)lab(/|$)') THEN 'Labs (ORU)'
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
        -- PDR data contributed before 2026-03-11 was only the HEADER information, not the clinical document; exclude it.
        AND i.last_modified_date >= timestamp '2026-03-11 00:00:00'
        AND i.size IS NOT NULL
        AND (
            regexp_like(lower(i.key), '(^|/)trn(/|$)')
            OR regexp_like(lower(i.key), '(^|/)ccd(/|$)')
            OR regexp_like(lower(i.key), '(^|/)lab(/|$)')
        )
)
SELECT
    doc_type,
    count(*) AS docs_20d,
    CAST(round(avg(doc_size_bytes), 0) AS bigint) AS avg_size_bytes,
    round(avg(doc_size_bytes) / pow(1024, 2), 3) AS avg_size_mb
FROM typed
WHERE doc_type IS NOT NULL
GROUP BY doc_type
ORDER BY doc_type;
