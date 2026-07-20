WITH config AS (
    SELECT
        TIMESTAMP '2026-03-01 00:00:00' AS start_ts,
        TIMESTAMP '2026-07-01 00:00:00' AS end_ts,
    2 AS inventory_snapshot_offset_days
),
target_snapshot AS (
    SELECT
        date_format(
            date_add('day', c.inventory_snapshot_offset_days - 1, date(c.end_ts)),
            '%Y-%m-%d-01-00'
        ) AS target_dt
    FROM config c
),
snapshot AS (
    SELECT
        max(i.dt) AS snapshot_dt
    FROM pdr_inventory.pdr_inventory_prod_data_all i
    CROSS JOIN target_snapshot t
    WHERE i.dt <= t.target_dt
),
filtered AS (
    SELECT
        date(i.last_modified_date) AS day,

        upper(
            regexp_replace(
                regexp_replace(i.bucket, '^nyec-pdr-prod-', ''),
                '-part2$',
                ''
            )
        ) AS qe,

        CASE
            WHEN regexp_like(lower(i.bucket), '-part2$') THEN 'PART2'
            ELSE 'NON_PART2'
        END AS part2_status

    FROM pdr_inventory.pdr_inventory_prod_data_all i
    CROSS JOIN config c
    CROSS JOIN snapshot s
    WHERE
        i.dt = s.snapshot_dt
        AND i.last_modified_date >= c.start_ts
        AND i.last_modified_date < c.end_ts
        AND i.bucket LIKE 'nyec-pdr-prod-%'
        AND i.is_latest = true
        AND coalesce(i.is_delete_marker, false) = false

        -- backload only
        AND regexp_like(lower(i.key), '(^|/)backload/')

        -- document types
        AND (
            regexp_like(lower(i.key), '(^|/)ccd(/|$)')
            OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
            OR regexp_like(lower(i.key), '(^|/)oru(/|$)')
        )
)
SELECT
    day,
    CASE
        WHEN day_of_week(day) IN (6, 7) THEN 'WEEKEND'
        ELSE 'WEEKDAY'
    END AS day_type,
    qe,
    part2_status,
    count(*) AS total_backload_documents
FROM filtered
GROUP BY 1, 2, 3, 4
ORDER BY 1, 2, 3, 4;