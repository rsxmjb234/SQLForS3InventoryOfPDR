```sql
/*
Expected cost/run: ~$0.95
Expected runtime: ~2 minutes

Goal:
- Show daily CCD submission counts for all hospitals in the baseline table.
- Exclude backlog data.
- Show 0 for days with no submissions.
- Support:
    processed/assigningAuthority/...
    error/assigningAuthority/...
    assigningAuthority/...
*/

WITH config AS (
    SELECT
        20 AS lookback_days,                 -- << CHANGE THIS
        3 AS inventory_lag_days,
        2 AS inventory_snapshot_offset_days
),

date_range AS (
    SELECT
        date_add(
            'day',
            -(c.lookback_days + c.inventory_lag_days - 1),
            current_date
        ) AS start_day,

        date_add(
            'day',
            -c.inventory_lag_days,
            current_date
        ) AS end_day,

        c.inventory_snapshot_offset_days

    FROM config c
),

days AS (
    SELECT
        d AS target_day

    FROM date_range c

    CROSS JOIN UNNEST(
        sequence(
            c.start_day,
            c.end_day,
            INTERVAL '1' DAY
        )
    ) AS t(d)
),

params AS (
    SELECT
        d.target_day,

        CAST(
            d.target_day AS timestamp
        ) AS day_start_ts,

        CAST(
            date_add('day', 1, d.target_day) AS timestamp
        ) AS day_end_ts,

        date_format(
            date_add(
                'day',
                c.inventory_snapshot_offset_days,
                d.target_day
            ),
            '%Y-%m-%d-01-00'
        ) AS dt_target_partition

    FROM days d
    CROSS JOIN date_range c
),

-- Deduplicate hospitals because the baseline has separate
-- Weekday/weekend rows for the same assigning authority.
hospitals AS (
    SELECT
        upper(trim(assigning_authority)) AS assigning_authority_key,
        min(trim(assigning_authority)) AS assigning_authority,
        min(qe) AS qe

    FROM pdr_inventory.lookup_stdev_average_for_hospitals

    WHERE metric = 'CCD'
      AND assigning_authority IS NOT NULL
      AND trim(assigning_authority) <> ''

    GROUP BY
        upper(trim(assigning_authority))
),

-- Every hospital × day combination.
expected AS (
    SELECT
        d.target_day AS day,
        h.assigning_authority_key,
        h.assigning_authority,
        h.qe

    FROM days d
    CROSS JOIN hospitals h
),

-- Parse and normalize the assigning authority before aggregation.
parsed_inventory AS (
    SELECT
        p.target_day AS day,

        upper(
            trim(
                CASE
                    WHEN lower(split_part(i.key, '/', 1))
                         IN ('processed', 'error')
                    THEN split_part(i.key, '/', 2)

                    ELSE split_part(i.key, '/', 1)
                END
            )
        ) AS assigning_authority_key

    FROM pdr_inventory.pdr_inventory_prod_data_all i

    JOIN params p
        ON i.dt = p.dt_target_partition
       AND i.last_modified_date >= p.day_start_ts
       AND i.last_modified_date < p.day_end_ts

    WHERE
        i.bucket LIKE 'nyec-pdr-prod-%'
        AND i.is_latest = true
        AND coalesce(i.is_delete_marker, false) = false

        -- Exclude backlog anywhere in the path.
        AND NOT regexp_like(
            lower(i.key),
            '(^|/)backload(/|$)'
        )

        -- CCD only.
        AND regexp_like(
            lower(i.key),
            '(^|/)ccd(/|$)'
        )
),

actual AS (
    SELECT
        p.day,
        p.assigning_authority_key,
        count(*) AS ccd_count

    FROM parsed_inventory p

    -- Limit aggregation to known hospital assigning authorities.
    INNER JOIN hospitals h
        ON p.assigning_authority_key = h.assigning_authority_key

    WHERE p.assigning_authority_key IS NOT NULL
      AND p.assigning_authority_key <> ''

    GROUP BY
        p.day,
        p.assigning_authority_key
)

SELECT
    e.qe,
    e.assigning_authority,
    date_format(e.day, '%Y-%m-%d') AS day,

    CASE
        WHEN day_of_week(e.day) IN (6, 7)
            THEN 'weekend'
        ELSE 'Weekday'
    END AS day_type,

    coalesce(a.ccd_count, 0) AS ccd_count

FROM expected e

LEFT JOIN actual a
    ON e.assigning_authority_key = a.assigning_authority_key
   AND e.day = a.day

ORDER BY
    e.qe ASC,
    e.assigning_authority ASC,
    e.day ASC;
```
