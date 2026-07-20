/*
Purpose:
  Compare HEALTHECONNECTIONS document sizes (CCD & TRN) against the average of all
  other QEs over the last 10 complete days.

Hypothesis being tested:
  If HEALTHECONNECTIONS is submitting incomplete / skeletal documents to hit volume
  targets faster, their per-document byte sizes will be significantly smaller than
  the rest-of-network average.

What it returns (two sections via UNION ALL):
  1. Per-QE / per-doc-type size statistics for the last 10 days:
       avg_size_bytes, median_size_bytes, p25_size_bytes, p75_size_bytes,
       min_size_bytes, max_size_bytes, doc_count
  2. A side-by-side comparison row: HEALTHECONNECTIONS vs. network average,
     with a pct_of_network_avg column < 100 meaning HC docs are smaller.

Key interpretation signals:
  - avg_size_bytes much smaller for HC  →  possible skeletal/incomplete documents
  - very low min_size_bytes for HC      →  near-empty files being submitted
  - tight p25-p75 range                →  uniformly small (template-sized) files
  - high doc_count + small size        →  speed without substance
*/

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 1: per-QE, per-doc-type size stats (last 10 complete days)
-- ─────────────────────────────────────────────────────────────────────────────
WITH filtered AS (
    SELECT
        regexp_replace(
            regexp_replace(bucket, '^nyec-pdr-prod-', ''),
            '-part2$', ''
        )                                                     AS qe,
        CASE
            WHEN regexp_like(lower(key), '(^|/)ccd(/|$)') THEN 'CCD'
            WHEN regexp_like(lower(key), '(^|/)trn(/|$)') THEN 'TRN'
        END                                                   AS doc_type,
        size                                                  AS size_bytes
    FROM pdr_inventory.pdr_inventory_prod_data_all
    WHERE
        -- Partition key 1: pin to only the nyec inventory sources (eliminates all other source partitions)
        inventory_source IN (
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
        -- Partition key 2: last 10 complete days
        AND dt BETWEEN date_format(date_add('day', -10, date(current_timestamp AT TIME ZONE 'America/New_York')), '%Y-%m-%d-01-00')
                  AND date_format(date_add('day', -1,  date(current_timestamp AT TIME ZONE 'America/New_York')), '%Y-%m-%d-01-00')
        -- bucket LIKE is redundant now that inventory_source is pinned above, but kept as a safety net
        AND bucket LIKE 'nyec-pdr-prod-%'
        AND is_latest = true
        AND coalesce(is_delete_marker, false) = false
        AND (
            regexp_like(lower(key), '(^|/)ccd(/|$)')
            OR regexp_like(lower(key), '(^|/)trn(/|$)')
        )
        AND last_modified_date > TIMESTAMP '2026-04-01 00:00:00'
        AND size > 0   -- exclude zero-byte placeholders
),

per_qe_stats AS (
    SELECT
        upper(qe)                                   AS qe,
        doc_type,
        count(*)                                    AS doc_count,
        round(avg(size_bytes))                      AS avg_size_bytes,
        approx_percentile(size_bytes, 0.50)         AS median_size_bytes,
        approx_percentile(size_bytes, 0.25)         AS p25_size_bytes,
        approx_percentile(size_bytes, 0.75)         AS p75_size_bytes,
        min(size_bytes)                             AS min_size_bytes,
        max(size_bytes)                             AS max_size_bytes
    FROM filtered
    GROUP BY 1, 2
),

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 2: network average (excluding HEALTHECONNECTIONS)
-- ─────────────────────────────────────────────────────────────────────────────
network_avg AS (
    SELECT
        doc_type,
        count(*)                                    AS doc_count,
        round(avg(size_bytes))                      AS avg_size_bytes,
        approx_percentile(size_bytes, 0.50)         AS median_size_bytes,
        approx_percentile(size_bytes, 0.25)         AS p25_size_bytes,
        approx_percentile(size_bytes, 0.75)         AS p75_size_bytes,
        min(size_bytes)                             AS min_size_bytes,
        max(size_bytes)                             AS max_size_bytes
    FROM filtered
    WHERE upper(qe) <> 'HEALTHECONNECTIONS'
    GROUP BY 1
)

-- ─────────────────────────────────────────────────────────────────────────────
-- Output A: all QEs ranked by avg_size_bytes within each doc_type
-- (HEALTHECONNECTIONS will stand out if it's an outlier)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    'PER_QE'                                        AS report_section,
    qe,
    doc_type,
    doc_count,
    avg_size_bytes,
    median_size_bytes,
    p25_size_bytes,
    p75_size_bytes,
    min_size_bytes,
    max_size_bytes,
    NULL                                            AS pct_of_network_avg,
    NULL                                            AS network_avg_size_bytes,
    NULL                                            AS network_median_size_bytes
FROM per_qe_stats

UNION ALL

-- ─────────────────────────────────────────────────────────────────────────────
-- Output B: HEALTHECONNECTIONS vs network side-by-side comparison
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
    'HC_VS_NETWORK'                                 AS report_section,
    'HEALTHECONNECTIONS'                            AS qe,
    hc.doc_type,
    hc.doc_count,
    hc.avg_size_bytes,
    hc.median_size_bytes,
    hc.p25_size_bytes,
    hc.p75_size_bytes,
    hc.min_size_bytes,
    hc.max_size_bytes,
    -- < 100 means HC docs are smaller than the network average (possible incompleteness)
    round(100.0 * hc.avg_size_bytes / NULLIF(net.avg_size_bytes, 0), 1)
                                                    AS pct_of_network_avg,
    net.avg_size_bytes                              AS network_avg_size_bytes,
    net.median_size_bytes                           AS network_median_size_bytes
FROM per_qe_stats hc
JOIN network_avg  net ON hc.doc_type = net.doc_type
WHERE hc.qe = 'HEALTHECONNECTIONS'

ORDER BY report_section DESC, doc_type, avg_size_bytes ASC;
