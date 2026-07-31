/*
Expected cost/run: ~$0.06 (scans ~12 GB for 1 day @ $5/TB)
Expected runtime: ~30 seconds

Goal:
- Understand the size distribution of CCD documents in the PDR.
- Groups documents into 5KB buckets from 0 to 20MB, then >20MB.
- Shows count and percentage for each bucket.
- Excludes backlog data.
- Uses 1 day of data (most recent reliable day) for a representative sample.

How to use:
- Run as-is for a quick snapshot.
- Change lookback_days for a larger sample (costs more).
*/

WITH config AS (
    SELECT
        5  AS lookback_days,                -- << CHANGE THIS for more data (costs ~$0.06/day)
        3  AS inventory_lag_days,
        2  AS inventory_snapshot_offset_days
),
date_range AS (
    SELECT
        date_add('day', -(c.lookback_days + c.inventory_lag_days - 1), current_date) AS start_day,
        date_add('day', -c.inventory_lag_days, current_date) AS end_day,
        c.inventory_snapshot_offset_days
    FROM config c
),
days AS (
    SELECT
        d AS target_day
    FROM date_range c
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
    CROSS JOIN date_range c
),

raw_sizes AS (
    SELECT
        i.size AS size_bytes
    FROM pdr_inventory.pdr_inventory_prod_data_all i
    JOIN params p
        ON i.dt = p.dt_target_partition
        AND i.last_modified_date >= p.day_start_ts
        AND i.last_modified_date < p.day_end_ts
    WHERE
        i.bucket LIKE 'nyec-pdr-prod-%'
        AND i.is_latest = true
        AND coalesce(i.is_delete_marker, false) = false
        AND NOT regexp_like(lower(i.key), '(^|/)backload(/|$)')
        AND regexp_like(lower(i.key), '(^|/)ccd(/|$)')
),

total AS (
    SELECT count(*) AS total_count FROM raw_sizes
),

bucketed AS (
    SELECT
        CASE
            WHEN size_bytes < 5000 THEN 1
            WHEN size_bytes < 10000 THEN 2
            WHEN size_bytes < 15000 THEN 3
            WHEN size_bytes < 20000 THEN 4
            WHEN size_bytes < 25000 THEN 5
            WHEN size_bytes < 50000 THEN 6
            WHEN size_bytes < 100000 THEN 7
            -- Fine-grained ranges for 100K-1MB (where 85% of data lives)
            WHEN size_bytes < 125000 THEN 8
            WHEN size_bytes < 150000 THEN 9
            WHEN size_bytes < 175000 THEN 10
            WHEN size_bytes < 200000 THEN 11
            WHEN size_bytes < 225000 THEN 12
            WHEN size_bytes < 250000 THEN 13
            WHEN size_bytes < 300000 THEN 14
            WHEN size_bytes < 350000 THEN 15
            WHEN size_bytes < 400000 THEN 16
            WHEN size_bytes < 450000 THEN 17
            WHEN size_bytes < 500000 THEN 18
            WHEN size_bytes < 550000 THEN 19
            WHEN size_bytes < 600000 THEN 20
            WHEN size_bytes < 650000 THEN 21
            WHEN size_bytes < 700000 THEN 22
            WHEN size_bytes < 750000 THEN 23
            WHEN size_bytes < 800000 THEN 24
            WHEN size_bytes < 850000 THEN 25
            WHEN size_bytes < 900000 THEN 26
            WHEN size_bytes < 950000 THEN 27
            WHEN size_bytes < 1000000 THEN 28
            -- Back to coarser ranges above 1MB
            WHEN size_bytes < 2000000 THEN 29
            WHEN size_bytes < 5000000 THEN 30
            WHEN size_bytes < 10000000 THEN 31
            WHEN size_bytes < 20000000 THEN 32
            ELSE 33
        END AS bucket_id,
        CASE
            WHEN size_bytes < 5000 THEN '<5,000'
            WHEN size_bytes < 10000 THEN '5,000-9,999'
            WHEN size_bytes < 15000 THEN '10,000-14,999'
            WHEN size_bytes < 20000 THEN '15,000-19,999'
            WHEN size_bytes < 25000 THEN '20,000-24,999'
            WHEN size_bytes < 50000 THEN '25,000-49,999'
            WHEN size_bytes < 100000 THEN '50,000-99,999'
            WHEN size_bytes < 125000 THEN '100,000-124,999'
            WHEN size_bytes < 150000 THEN '125,000-149,999'
            WHEN size_bytes < 175000 THEN '150,000-174,999'
            WHEN size_bytes < 200000 THEN '175,000-199,999'
            WHEN size_bytes < 225000 THEN '200,000-224,999'
            WHEN size_bytes < 250000 THEN '225,000-249,999'
            WHEN size_bytes < 300000 THEN '250,000-299,999'
            WHEN size_bytes < 350000 THEN '300,000-349,999'
            WHEN size_bytes < 400000 THEN '350,000-399,999'
            WHEN size_bytes < 450000 THEN '400,000-449,999'
            WHEN size_bytes < 500000 THEN '450,000-499,999'
            WHEN size_bytes < 550000 THEN '500,000-549,999'
            WHEN size_bytes < 600000 THEN '550,000-599,999'
            WHEN size_bytes < 650000 THEN '600,000-649,999'
            WHEN size_bytes < 700000 THEN '650,000-699,999'
            WHEN size_bytes < 750000 THEN '700,000-749,999'
            WHEN size_bytes < 800000 THEN '750,000-799,999'
            WHEN size_bytes < 850000 THEN '800,000-849,999'
            WHEN size_bytes < 900000 THEN '850,000-899,999'
            WHEN size_bytes < 950000 THEN '900,000-949,999'
            WHEN size_bytes < 1000000 THEN '950,000-999,999'
            WHEN size_bytes < 2000000 THEN '1,000,000-1,999,999'
            WHEN size_bytes < 5000000 THEN '2,000,000-4,999,999'
            WHEN size_bytes < 10000000 THEN '5,000,000-9,999,999'
            WHEN size_bytes < 20000000 THEN '10,000,000-19,999,999'
            ELSE '>20,000,000'
        END AS size_in_bytes,
        CASE
            WHEN size_bytes < 5000 THEN '<0.005'
            WHEN size_bytes < 10000 THEN '0.005-0.01'
            WHEN size_bytes < 15000 THEN '0.01-0.015'
            WHEN size_bytes < 20000 THEN '0.015-0.02'
            WHEN size_bytes < 25000 THEN '0.02-0.025'
            WHEN size_bytes < 50000 THEN '0.025-0.05'
            WHEN size_bytes < 100000 THEN '0.05-0.1'
            WHEN size_bytes < 125000 THEN '0.1-0.12'
            WHEN size_bytes < 150000 THEN '0.12-0.14'
            WHEN size_bytes < 175000 THEN '0.14-0.17'
            WHEN size_bytes < 200000 THEN '0.17-0.19'
            WHEN size_bytes < 225000 THEN '0.19-0.21'
            WHEN size_bytes < 250000 THEN '0.21-0.24'
            WHEN size_bytes < 300000 THEN '0.24-0.29'
            WHEN size_bytes < 350000 THEN '0.29-0.33'
            WHEN size_bytes < 400000 THEN '0.33-0.38'
            WHEN size_bytes < 450000 THEN '0.38-0.43'
            WHEN size_bytes < 500000 THEN '0.43-0.48'
            WHEN size_bytes < 550000 THEN '0.48-0.52'
            WHEN size_bytes < 600000 THEN '0.52-0.57'
            WHEN size_bytes < 650000 THEN '0.57-0.62'
            WHEN size_bytes < 700000 THEN '0.62-0.67'
            WHEN size_bytes < 750000 THEN '0.67-0.71'
            WHEN size_bytes < 800000 THEN '0.71-0.76'
            WHEN size_bytes < 850000 THEN '0.76-0.81'
            WHEN size_bytes < 900000 THEN '0.81-0.86'
            WHEN size_bytes < 950000 THEN '0.86-0.91'
            WHEN size_bytes < 1000000 THEN '0.91-0.95'
            WHEN size_bytes < 2000000 THEN '0.95-1.9'
            WHEN size_bytes < 5000000 THEN '1.9-4.8'
            WHEN size_bytes < 10000000 THEN '4.8-9.5'
            WHEN size_bytes < 20000000 THEN '9.5-19.1'
            ELSE '>19.1'
        END AS size_in_mb
    FROM raw_sizes
)

SELECT
    b.size_in_bytes,
    b.size_in_mb,
    count(*) AS number,
    CAST(round(100.0 * count(*) / t.total_count, 2) AS varchar) || '%' AS pct
FROM bucketed b
CROSS JOIN total t
GROUP BY b.bucket_id, b.size_in_bytes, b.size_in_mb, t.total_count
ORDER BY b.bucket_id ASC;
