/*
Purpose:
- Debug unexpected AssigningAuthority values (for example, AssigningAuthority = 'CCD').

What this query does:
- Pulls up to 100 full key values for one day and one QE where AssigningAuthority resolves to 'ccd'.
- Shows bucket, inventory_source, and last_modified_date so path patterns can be inspected.

Why this is useful:
- AssigningAuthority is derived from key path segments. If path structure varies,
  values like 'CCD' can appear as the first/second segment and be interpreted as authority.
- This output helps confirm the actual key format driving that classification.
*/

WITH sample AS (
    SELECT
        CAST(substr(dt, 1, 10) AS date) AS day,
        regexp_replace(regexp_replace(bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS qe,
        CASE
            WHEN lower(key) LIKE 'backload/%' THEN split_part(key, '/', 2)
            ELSE split_part(key, '/', 1)
        END AS assigning_authority,
        key,
        bucket,
        inventory_source,
        last_modified_date
    FROM pdr_inventory.pdr_inventory_prod_data_all
    WHERE dt = '2026-05-18-01-00'
      AND is_latest = true
      AND coalesce(is_delete_marker, false) = false
      AND bucket LIKE 'nyec-pdr-prod-%'
)
SELECT
    day,
    upper(qe) AS qe,
    assigning_authority,
    bucket,
    inventory_source,
    last_modified_date,
    key
FROM sample
WHERE lower(qe) = 'bronx'
  AND lower(assigning_authority) = 'ccd'
ORDER BY last_modified_date DESC
LIMIT 100;