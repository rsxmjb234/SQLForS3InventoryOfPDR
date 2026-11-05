/*
Goal:
- Find system-wide BULK SPIKE DAYS (data artifacts like 2026-09-22) by showing
  total documents submitted PER DAY across ALL QEs, plus the per-QE breakdown,
  so abnormally high days stand out and can be added to the exclusion rule.

Method:
- One row per day in the window, with total docs and a per-QE split.
- A "spike day" is any day whose total is many multiples of the typical day.

Conventions (same as the volume queries):
- Reads ONE recent inventory snapshot.
- Excludes data before 2026-03-11 (header-only "bad date" rule).
- Excludes backload (real-time submissions only).
- NOTE: 2026-09-22 is NOT excluded here on purpose - this query is for FINDING
  spike days, so we need to see them.

IMPORTANT - dating is INTENTIONALLY by last_modified_date here:
- Unlike the volume queries (which bucket by the TRUE submission date parsed
  from the key path), this query deliberately buckets by last_modified_date.
  Its whole purpose is to surface the re-stamp ARTIFACT days - the bulk events
  that re-stamp millions of older docs to a later last_modified_date. Those
  spikes only appear when you count by last_modified_date, so DO NOT convert
  this query to the key-parsed submission date; that would hide the very
  artifacts it is meant to find.

Default window: all of September 2026 (edit start_day / end_day to scan more).
*/

WITH config AS (
    SELECT
        DATE '2026-09-01' AS start_day,                -- << first day to scan
        DATE '2026-09-30' AS end_day,                  -- << last day to scan
        date_format(date_add('day', -2, current_date), '%Y-%m-%d-01-00') AS single_snapshot_dt
),

docs AS (
    SELECT
        CAST(i.last_modified_date AS date) AS day,
        regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS qe
    FROM pdr_inventory.pdr_inventory_prod_data_all i
    CROSS JOIN config c
    WHERE
        i.dt = c.single_snapshot_dt
        AND i.bucket LIKE 'nyec-pdr-prod-%'
        AND i.is_latest = true
        AND coalesce(i.is_delete_marker, false) = false
        AND i.last_modified_date >= timestamp '2026-03-11 00:00:00'
        -- GLOBAL RULE: exclude processed/ and error/ workflow-prefix objects
        -- (historical FHIR-processing copies; see rules.md). Dropped like the date rule.
        AND NOT regexp_like(lower(i.key), '^(processed|error)/')
        AND i.last_modified_date >= CAST(c.start_day AS timestamp)
        AND i.last_modified_date <  CAST(date_add('day', 1, c.end_day) AS timestamp)
        AND NOT regexp_like(lower(i.key), '(^|/)backload/')
        AND (
            regexp_like(lower(i.key), '(^|/)ccd(/|$)')
            OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
            OR regexp_like(lower(i.key), '(^|/)lab(/|$)')
        )
)

SELECT
    date_format(day, '%Y-%m-%d') AS day,
    CASE WHEN day_of_week(day) IN (6, 7) THEN 'weekend' ELSE 'weekday' END AS day_type,
    count(*) AS total_docs,
    count_if(qe = 'bronx')              AS bronx,
    count_if(qe = 'healtheconnections') AS healtheconnections,
    count_if(qe = 'healthix')           AS healthix,
    count_if(qe = 'hixny')              AS hixny,
    count_if(qe = 'rochester')          AS rochester,
    count_if(qe = 'techbd')             AS techbd
FROM docs
GROUP BY day
ORDER BY day ASC;
