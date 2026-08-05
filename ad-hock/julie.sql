/*
findcandidatesforexplore.sql — Get 5 random document S3 paths per assigning authority

Based on Dan's SQL with these additions:
  1. Includes ALL path types (normal, processed, error, backload)
  2. Handles all path prefixes for AA derivation
  3. ALL document types (CCD, TRN, ORU) from every source
  4. 10-day window (Jul 15-24) to catch intermittent/backlog sources
  5. 5 random samples per assigning authority
  6. "path" column = full key minus the filename (everything left of the final /)

Output columns: assigning_authority, qe, bucket, key, path, size, last_modified
  - These match what findandsaveEHRfromCCD-EntireCCD.py expects via read_input_csv_file()
  - Export this from Athena as CSV, then feed it to the Python script
*/

WITH ranked AS (
    SELECT
        trim(
            CASE
                WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error', 'backload')
                THEN split_part(i.key, '/', 2)
                ELSE split_part(i.key, '/', 1)
            END
        ) AS assigning_authority,

        regexp_replace(
            regexp_replace(i.bucket, '^nyec-pdr-prod-', ''),
            '-part2$',
            ''
        ) AS qe,

        i.bucket,
        i.key,
        -- Path = key without the filename (everything left of the last /)
        substr(i.key, 1, length(i.key) - length(split_part(i.key, '/', cardinality(split(i.key, '/')))) - 1) AS path,
        i.size,
        i.last_modified_date,

        row_number() OVER (
            PARTITION BY
                trim(
                    CASE
                        WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error', 'backload')
                        THEN split_part(i.key, '/', 2)
                        ELSE split_part(i.key, '/', 1)
                    END
                )
            ORDER BY random()
        ) AS rn

    FROM pdr_inventory.pdr_inventory_prod_data_all i

    WHERE
        -- 10-day window: Jul 15-24, with dt partitions offset by +2 days
        i.dt IN (
            '2026-07-17-01-00',
            '2026-07-18-01-00',
            '2026-07-19-01-00',
            '2026-07-20-01-00',
            '2026-07-21-01-00',
            '2026-07-22-01-00',
            '2026-07-23-01-00',
            '2026-07-24-01-00',
            '2026-07-25-01-00',
            '2026-07-26-01-00'
        )
        AND i.last_modified_date >= timestamp '2026-07-15 00:00:00'
        AND i.last_modified_date <  timestamp '2026-07-25 00:00:00'

        AND i.bucket LIKE 'nyec-pdr-prod-%'
        AND i.is_latest = true
        AND coalesce(i.is_delete_marker, false) = false

)

SELECT
    assigning_authority,
    qe,
    bucket,
    key,
    path,
    size,
    date_format(last_modified_date, '%Y-%m-%d %H:%i:%s') AS last_modified
FROM ranked
WHERE rn <= 5
ORDER BY assigning_authority, last_modified DESC;
