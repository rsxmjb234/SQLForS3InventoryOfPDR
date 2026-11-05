/*
Goal:
- Explore an ANOMALY DAY. We saw one source (bronx / MHHC) explode on 2026-09-22.
  Were they alone, or did OTHER sources also spike (> 100% above their normal
  daily volume) that same day?
- For every source (QE + assigning authority), compare its document count on the
  anomaly day to its NORMAL daily average over a trailing baseline window, and
  rank by how far above normal the anomaly day was.

Method:
- "Normal" = average documents/day for that source over the baseline window
  (default: the 14 days immediately BEFORE the anomaly day).
- spike_pct = (anomaly_day_count - avg_baseline_per_day) / avg_baseline_per_day.
  A source "spiked" if spike_pct > 100% (anomaly day more than double normal).
- Counts ALL required data types combined (CCD + TRN + Lab); change the type
  filter if you want to isolate one.

Conventions (same as the other volume/drilldown queries):
- Reads ONE recent inventory snapshot, bucketed by last_modified_date.
- Excludes data before 2026-03-11 (header-only "bad date" rule).
- Excludes backload (real-time submissions only).
- QE = bucket name minus nyec-pdr-prod- prefix and -part2 suffix.
- Assigning authority = path segment 2 if first segment is processed/error/
  backload, else segment 1.
- Labs = 'lab' path segment (per rules.md), NOT 'oru'.

To reuse for another day: edit anomaly_day (and baseline_days if desired).
*/

WITH config AS (
    SELECT
        DATE '2026-09-22' AS anomaly_day,              -- << the day to investigate
        14 AS baseline_days,                           -- << trailing days used as "normal"
        date_format(date_add('day', -2, current_date), '%Y-%m-%d-01-00') AS single_snapshot_dt
),

-- One row per doc for the anomaly day + the trailing baseline window, tagged
-- as either the anomaly day ('ANOMALY') or part of the baseline ('BASE').
scoped AS (
    SELECT
        regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS qe,
        upper(trim(
            CASE
                WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error', 'backload')
                THEN split_part(i.key, '/', 2)
                ELSE split_part(i.key, '/', 1)
            END
        )) AS assigning_authority,
        CASE
            WHEN CAST(i.last_modified_date AS date) = c.anomaly_day THEN 'ANOMALY'
            ELSE 'BASE'
        END AS bucket_label
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
        -- window = [anomaly_day - baseline_days, anomaly_day + 1 day)
        AND i.last_modified_date >= CAST(date_add('day', -c.baseline_days, c.anomaly_day) AS timestamp)
        AND i.last_modified_date <  CAST(date_add('day', 1, c.anomaly_day) AS timestamp)
        AND NOT regexp_like(lower(i.key), '(^|/)backload/')
        AND (
            regexp_like(lower(i.key), '(^|/)ccd(/|$)')
            OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
            OR regexp_like(lower(i.key), '(^|/)lab(/|$)')
        )
),

per_source AS (
    SELECT
        qe,
        assigning_authority,
        count_if(bucket_label = 'ANOMALY') AS anomaly_day_count,
        count_if(bucket_label = 'BASE')    AS baseline_total
    FROM scoped
    WHERE assigning_authority IS NOT NULL AND assigning_authority <> ''
    GROUP BY qe, assigning_authority
),

scored AS (
    SELECT
        p.qe,
        p.assigning_authority,
        p.anomaly_day_count,
        p.baseline_total,
        -- average docs/day over the baseline window
        CAST(round(p.baseline_total * 1.0 / c.baseline_days, 1) AS double) AS avg_baseline_per_day,
        CASE
            WHEN p.baseline_total = 0 AND p.anomaly_day_count > 0 THEN NULL  -- brand new that day
            WHEN p.baseline_total = 0 THEN NULL
            ELSE CAST(round(
                100.0 * (p.anomaly_day_count - (p.baseline_total * 1.0 / c.baseline_days))
                / (p.baseline_total * 1.0 / c.baseline_days)
            ) AS bigint)
        END AS spike_pct
    FROM per_source p
    CROSS JOIN config c
)

SELECT
    qe,
    assigning_authority,
    anomaly_day_count,
    avg_baseline_per_day,
    spike_pct,
    CASE
        WHEN baseline_total = 0 AND anomaly_day_count > 0 THEN 'NEW (no baseline, appeared on anomaly day)'
        WHEN spike_pct IS NULL THEN 'no baseline'
        WHEN spike_pct > 100 THEN 'SPIKE (>100% above normal)'
        WHEN spike_pct > 0 THEN 'up'
        WHEN spike_pct = 0 THEN 'flat'
        ELSE 'down'
    END AS status
FROM scored
-- Only show sources that were active on the anomaly day; most-anomalous first.
WHERE anomaly_day_count > 0
ORDER BY
    CASE WHEN baseline_total = 0 THEN 1 ELSE 0 END ASC,   -- real spikes before "new" sources
    spike_pct DESC NULLS LAST,
    anomaly_day_count DESC;
