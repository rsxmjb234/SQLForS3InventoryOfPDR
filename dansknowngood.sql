/*
Code given by Dan that is a known good baseline code to pull data and group as backlod
or not backload and tag by data type.

*/

WITH typed AS (
    SELECT
        bucket,

        CASE
            WHEN regexp_like(lower(key), '(^|/)backload/') THEN 'BACKLOAD'
            ELSE 'NON_BACKLOAD'
        END AS load_type,

        CASE
            WHEN regexp_like(lower(key), '(^|/)trn(/|$)') THEN 'TRN'
            WHEN regexp_like(lower(key), '(^|/)ccd(/|$)') THEN 'CCD'
        END AS doc_type,

        last_modified_date,
        key
    FROM pdr_inventory.pdr_inventory_prod_data_all
    WHERE inventory_source IN (
        'nyec-pdr-prod-hixny',
        'nyec-pdr-prod-hixny-part2',
        'nyec-pdr-prod-bronx',
        'nyec-pdr-prod-bronx-part2',
        'nyec-pdr-prod-healtheconnections',
        'nyec-pdr-prod-healtheconnections-part2',
        'nyec-pdr-prod-healthix',
        'nyec-pdr-prod-healthix-part2',
        'nyec-pdr-prod-techbd',
        'nyec-pdr-prod-techbd-part2',
        'nyec-pdr-prod-rochester',
        'nyec-pdr-prod-rochester-part2'
    )
      AND dt = '2026-06-16-01-00'
      AND is_latest = true
      AND coalesce(is_delete_marker, false) = false
      AND (
          regexp_like(lower(key), '(^|/)trn(/|$)')
          OR regexp_like(lower(key), '(^|/)ccd(/|$)')
      )
),

ranked AS (
    SELECT
        *,
        row_number() OVER (
            PARTITION BY bucket, load_type, doc_type
            ORDER BY last_modified_date DESC
        ) AS rn
    FROM typed
    WHERE doc_type IS NOT NULL
)

SELECT
    bucket,
    load_type,
    doc_type,
    last_modified_date,
    key
FROM ranked
WHERE rn = 1
ORDER BY bucket, load_type, doc_type;