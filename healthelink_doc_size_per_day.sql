/*
Purpose:
  Show HEALTHELINK average, median, min, and max document size (bytes) per day
  for CCD and TRN objects, from 2026-03-01 through today.

Why this matters:
  A median of 46 bytes is effectively an empty file — a valid CCD or TRN should
  be tens of thousands of bytes. This report tracks whether the problem started
  on a specific date, is getting worse, or is consistent across the full period.

Key logic:
  - Uses the most recent inventory snapshot (yesterday's dt) as the data source.
  - Groups by last_modified_date (true event day), not dt (snapshot day).
  - CCD and TRN are reported separately so trends can be compared.
*/

WITH filtered AS (
    SELECT
        date(last_modified_date)                    AS day,
        CASE
            WHEN regexp_like(lower(key), '(^|/)ccd(/|$)') THEN 'CCD'
            WHEN regexp_like(lower(key), '(^|/)trn(/|$)') THEN 'TRN'
        END                                         AS doc_type,
        size                                        AS size_bytes
    FROM pdr_inventory.pdr_inventory_prod_data_all
    WHERE
        -- Partition key 1: HEALTHELINK buckets only
        inventory_source IN (
            'nyec-pdr-prod-healthelink',
            'nyec-pdr-prod-healthelink-part2'
        )
        -- Partition key 2: most recent complete daily snapshot
        AND dt = date_format(date_add('day', -1, date(current_timestamp AT TIME ZONE 'America/New_York')), '%Y-%m-%d-01-00')
        -- Event-time window: 2026-03-01 through end of today (ET)
        AND last_modified_date >= TIMESTAMP '2026-03-01 00:00:00'
        AND last_modified_date <  date_add('day', 1, date(current_timestamp AT TIME ZONE 'America/New_York'))
        AND is_latest = true
        AND coalesce(is_delete_marker, false) = false
        AND (
            regexp_like(lower(key), '(^|/)ccd(/|$)')
            OR regexp_like(lower(key), '(^|/)trn(/|$)')
        )
        -- include zero-byte files on purpose — they are part of the problem signal
)

SELECT
    day,
    doc_type,
    count(*)                                        AS doc_count,
    round(avg(size_bytes))                          AS avg_size_bytes,
    approx_percentile(size_bytes, 0.50)             AS median_size_bytes,
    approx_percentile(size_bytes, 0.25)             AS p25_size_bytes,
    approx_percentile(size_bytes, 0.75)             AS p75_size_bytes,
    min(size_bytes)                                 AS min_size_bytes,
    max(size_bytes)                                 AS max_size_bytes,
    -- how many docs are suspiciously tiny (< 500 bytes = essentially empty)
    count_if(size_bytes < 500)                      AS tiny_doc_count,
    round(100.0 * count_if(size_bytes < 500) / count(*), 1)
                                                    AS pct_tiny
FROM filtered
GROUP BY 1, 2
ORDER BY 1, 2;
