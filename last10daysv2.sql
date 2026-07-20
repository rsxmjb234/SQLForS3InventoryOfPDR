/*
Purpose:
- Summarize last 10 complete days of PDR inventory activity for TRN and CCD documents.
- With QE parsed from the S3 path.

What it returns:
- Daily counts by bucket, normalized QE (bucket with -part2 removed), assigning authority,
    load type (BACKLOAD vs NON_BACKLOAD), and document type (TRN or CCD).

Key logic:
- Uses dt partition filter for last 10 full days (excludes today).
- Keeps latest, non-delete-marker records only.
- Derives assigning_authority from key path:
    - backload/... uses path segment 2
    - all other paths use path segment 1
*/

/* example  of returned result
day	bucket	qe	assigning_authority	load_type	doc_type	doc_count
5/18/2026	bronx	bronx	2.16.840.1.113883.13.61	BACKLOAD	CCD	79
5/18/2026	bronx	bronx	2.16.840.1.113883.13.61	NON_BACKLOAD	CCD	2
*/ 


/*
Optional helper query (run separately, not with main query):

SELECT
    inventory_source,
    count(*) AS partition_days
FROM pdr_inventory.pdr_inventory_prod_data_all$partitions
WHERE dt BETWEEN date_format(date_add('day', -10, date(current_timestamp AT TIME ZONE 'America/New_York')), '%Y-%m-%d-01-00')
            AND date_format(date_add('day', -1, date(current_timestamp AT TIME ZONE 'America/New_York')), '%Y-%m-%d-01-00')
GROUP BY 1
ORDER BY 2 DESC, 1
*/

/*
Lowest-scan exact pattern:
1) Keep dt filter (partition key).
2) Add inventory_source IN (...) with real values (partition key).
3) Add bucket filter if only nyec buckets are needed.
*/

-- Main query: one statement only (Athena requirement).
WITH filtered AS (
    SELECT
        CAST(substr(dt, 1, 10) AS date) AS day,
        regexp_replace(bucket, '^nyec-pdr-prod-', '') AS bucket,
        regexp_replace(regexp_replace(bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS qe,
        CASE
            WHEN lower(key) LIKE 'backload/%' THEN split_part(key, '/', 2)
            ELSE split_part(key, '/', 1)
        END AS assigning_authority,
        lower(key) AS key_lc
    FROM pdr_inventory.pdr_inventory_prod_data_all
    WHERE
        -- Highest impact filter: list only real inventory_source values you need.
        -- inventory_source IN ('real-source-1', 'real-source-2')
        dt BETWEEN date_format(date_add('day', -10, date(current_timestamp AT TIME ZONE 'America/New_York')), '%Y-%m-%d-01-00')
                  AND date_format(date_add('day', -1, date(current_timestamp AT TIME ZONE 'America/New_York')), '%Y-%m-%d-01-00')
        AND bucket LIKE 'nyec-pdr-prod-%'
        AND is_latest = true
        AND coalesce(is_delete_marker, false) = false
        AND (
            regexp_like(lower(key), '(^|/)trn(/|$)')
            OR regexp_like(lower(key), '(^|/)ccd(/|$)')
        )
)
SELECT
    day,
    bucket,
    qe,
    assigning_authority,
    CASE
        WHEN regexp_like(key_lc, '(^|/)backload/') THEN 'BACKLOAD'
        ELSE 'NON_BACKLOAD'
    END AS load_type,
    CASE
        WHEN regexp_like(key_lc, '(^|/)trn(/|$)') THEN 'TRN'
        WHEN regexp_like(key_lc, '(^|/)ccd(/|$)') THEN 'CCD'
    END AS doc_type,
    count(*) AS doc_count
FROM filtered
GROUP BY 1, 2, 3, 4, 5, 6
ORDER BY 1, 2, 3, 4, 5, 6;