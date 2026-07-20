# Step 1 (replace `<Your-S3-Path>`) with the path to the bucket/prefix of NYeC's CSV with the assigning authorities by QE:

```sql
CREATE EXTERNAL TABLE `hospital_aa_reference`(
  `organization_type` string COMMENT 'from deserializer', 
  `assigning_authority` string COMMENT 'from deserializer', 
  `qe_name` string COMMENT 'from deserializer')
ROW FORMAT SERDE 
  'org.apache.hadoop.hive.serde2.OpenCSVSerde' 
WITH SERDEPROPERTIES ( 
  'escapeChar'='\\', 
  'quoteChar'='\"', 
  'separatorChar'=',') 
STORED AS INPUTFORMAT 
  'org.apache.hadoop.mapred.TextInputFormat' 
OUTPUTFORMAT 
  'org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat'
LOCATION
  '<Your-S3-Path>'
TBLPROPERTIES (
  'skip.header.line.count'='1', 
  'transient_lastDdlTime'='1783694454', 
  'use.null.for.invalid.data'='true')
```

# Step 2 - run query to generate NYeC stddev baseline (we'll create the table using this next, make note of where you upload):

```sql
/*
Goal:
- Compute hospital CCD/TRN baselines over the configured date range.
- Include zero-volume days.
- Exclude backlog.
- Support these key structures:
    processed/assigningAuthority/...
    error/assigningAuthority/...
    assigningAuthority/...
- Limit results to assigning authorities in hospital_aa_reference.
- Deduplicate hospital_aa_reference before matching inventory.

Output:
- Download these results as CSV.
- Upload to the S3 prefix used by:
    pdr_inventory.lookup_stdev_average_for_hospitals
*/

WITH config AS (
    SELECT
        30 AS lookback_days,
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

-- One row per assigning authority.
-- Most authorities map to one QE. If an authority appears under multiple
-- QEs in the reference file, retain them as a comma-separated value.
hospital_refs AS (
    SELECT
        upper(trim(assigning_authority)) AS assigning_authority_key,

        min(trim(assigning_authority)) AS assigning_authority,

        array_join(
            array_sort(
                array_distinct(
                    array_agg(
                        upper(trim(qe_name))
                    )
                )
            ),
            ', '
        ) AS qe

    FROM pdr_inventory.hospital_aa_reference

    WHERE assigning_authority IS NOT NULL
      AND trim(assigning_authority) <> ''

    GROUP BY
        upper(trim(assigning_authority))
),

-- Read inventory rows for each target day and normalize the AA path segment.
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
        ) AS assigning_authority_key,

        CASE
            WHEN regexp_like(
                lower(i.key),
                '(^|/)ccd(/|$)'
            )
            THEN 'CCD'

            WHEN regexp_like(
                lower(i.key),
                '(^|/)trn(/|$)'
            )
            THEN 'TRN'
        END AS doc_type

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

        -- Include CCD and TRN only.
        AND (
            regexp_like(
                lower(i.key),
                '(^|/)ccd(/|$)'
            )
            OR regexp_like(
                lower(i.key),
                '(^|/)trn(/|$)'
            )
        )
),

-- Daily submission counts, limited to hospital assigning authorities.
actual_daily AS (
    SELECT
        p.day,
        p.assigning_authority_key,
        count_if(p.doc_type = 'CCD') AS ccd_count,
        count_if(p.doc_type = 'TRN') AS trn_count

    FROM parsed_inventory p

    INNER JOIN hospital_refs h
        ON p.assigning_authority_key = h.assigning_authority_key

    WHERE p.assigning_authority_key IS NOT NULL
      AND p.assigning_authority_key <> ''

    GROUP BY
        p.day,
        p.assigning_authority_key
),

-- Create every hospital × day combination.
-- This is what causes missing days to be represented as zero.
expected_daily AS (
    SELECT
        d.target_day AS day,

        CASE
            WHEN day_of_week(d.target_day) IN (6, 7)
            THEN 'weekend'
            ELSE 'Weekday'
        END AS day_type,

        h.assigning_authority_key,
        h.assigning_authority,
        h.qe

    FROM days d
    CROSS JOIN hospital_refs h
),

daily_counts AS (
    SELECT
        e.day,
        e.day_type,
        e.assigning_authority,
        e.assigning_authority_key,
        e.qe,

        coalesce(
            a.ccd_count,
            0
        ) AS ccd_count,

        coalesce(
            a.trn_count,
            0
        ) AS trn_count

    FROM expected_daily e

    LEFT JOIN actual_daily a
        ON e.assigning_authority_key = a.assigning_authority_key
       AND e.day = a.day
),

-- Convert CCD and TRN into separate metric rows.
metric_rows AS (
    SELECT
        assigning_authority,
        qe,
        day_type,
        day,
        'CCD' AS metric,
        ccd_count AS daily_value

    FROM daily_counts

    UNION ALL

    SELECT
        assigning_authority,
        qe,
        day_type,
        day,
        'TRN' AS metric,
        trn_count AS daily_value

    FROM daily_counts
),

stats AS (
    SELECT
        assigning_authority,
        qe,
        day_type,
        metric,

        CAST(
            round(
                avg(daily_value)
            ) AS bigint
        ) AS mean_value,

        CAST(
            coalesce(
                round(
                    stddev(daily_value)
                ),
                0
            ) AS bigint
        ) AS stdev_value,

        count(*) AS sample_days,

        date_diff(
            'day',
            DATE '1970-01-01',
            min(day)
        ) AS baseline_start_epoch_day,

        date_diff(
            'day',
            DATE '1970-01-01',
            max(day)
        ) AS baseline_end_epoch_day

    FROM metric_rows

    GROUP BY
        assigning_authority,
        qe,
        day_type,
        metric
)

SELECT
    assigning_authority,
    qe,
    day_type,
    metric,
    mean_value,
    stdev_value,
    sample_days,
    baseline_start_epoch_day,
    baseline_end_epoch_day,

    CAST(
        greatest(
            0,
            mean_value - (2 * coalesce(stdev_value, 0))
        ) AS bigint
    ) AS lower_2stdev,

    CAST(
        mean_value + (2 * coalesce(stdev_value, 0))
        AS bigint
    ) AS upper_2stdev

FROM stats

ORDER BY
    assigning_authority ASC,
    metric ASC,
    day_type ASC;
```

# Step 3 - Create table for stddev, change your location to point to the one from step 2:

```sql
CREATE EXTERNAL TABLE pdr_inventory.lookup_stdev_average_for_hospitals (
  assigning_authority string,
  qe string,
  day_type string,
  metric string,
  mean_value bigint,
  stdev_value bigint,
  sample_days int,
  baseline_start_epoch_day bigint,
  baseline_end_epoch_day bigint,
  lower_2stdev bigint,
  upper_2stdev bigint
)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES (
  'separatorChar' = ',',
  'quoteChar' = '"',
  'escapeChar' = '\\'
)
STORED AS TEXTFILE
LOCATION '<Location from step 2>'
TBLPROPERTIES (
  'skip.header.line.count'='1',
  'use.null.for.invalid.data'='true'
);
```

# Step 4 - Use the corrected queries:

## TRN:

```sql
/*
Goal:
- Show daily TRN submission counts for all hospitals in the baseline table.
- Exclude backlog data.
- Show 0 for days with no submissions.
- Support:
    processed/assigningAuthority/...
    error/assigningAuthority/...
    assigningAuthority/...
*/

WITH config AS (
    SELECT
        30 AS lookback_days,
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
        CAST(d.target_day AS timestamp) AS day_start_ts,
        CAST(date_add('day', 1, d.target_day) AS timestamp) AS day_end_ts,
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

-- One row per hospital from the baseline table.
hospitals AS (
    SELECT
        upper(trim(assigning_authority)) AS assigning_authority_key,
        min(trim(assigning_authority)) AS assigning_authority,
        min(qe) AS qe
    FROM pdr_inventory.lookup_stdev_average_for_hospitals
    WHERE metric = 'TRN'
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

-- Parse and normalize assigning authorities before aggregation.
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

        -- TRN only.
        AND regexp_like(
            lower(i.key),
            '(^|/)trn(/|$)'
        )
),

actual AS (
    SELECT
        day,
        assigning_authority_key,
        count(*) AS trn_count
    FROM parsed_inventory
    WHERE assigning_authority_key IS NOT NULL
      AND assigning_authority_key <> ''
    GROUP BY
        day,
        assigning_authority_key
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

    coalesce(a.trn_count, 0) AS trn_count

FROM expected e

LEFT JOIN actual a
    ON e.assigning_authority_key = a.assigning_authority_key
   AND e.day = a.day

ORDER BY
    e.qe ASC,
    e.assigning_authority ASC,
    e.day ASC;
```

## CCD:

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
