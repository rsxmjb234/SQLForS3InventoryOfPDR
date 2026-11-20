/*
Expected cost/run: ~$0.01-0.05 (ONE inventory snapshot, two buckets, a few GB)
Expected runtime: ~30 seconds

Ad hoc: find when a QE's data stopped arriving, when it came back, and how much data
is likely missing. Each bucket is checked on its own, so you can see whether the
regular feed and the Part 2 feed behaved differently.
Built for the Hixny Nov 11-16, 2026 outage
(see ISSUE-Hixny-PDR-Outage-Nov11-to-Nov16-2026.md).

How to use:
- Set qe, range_start, snapshot_dt and gap_threshold_minutes in config.
- snapshot_dt must be AFTER the outage ended, or the end shows as 'OPEN at snapshot'.
  The inventory snapshot is written about 01:00 UTC each day. A feed that resumes
  later that day only shows up in the NEXT day's snapshot.

Output:
  row_type = 'GAP'     one row per bucket gap of at least gap_threshold_minutes:
                       gap start (last arrival before), gap end (first arrival after,
                       or OPEN), length, and the likely missing volume = what the same
                       bucket received in the same clock window one week earlier
                       (CCD, TRN, LAB).
  row_type = 'BUCKET'  one row per bucket: arrivals since range_start, newest
                       arrival, and the longest gap. A bucket with no GAP rows kept
                       working.

Rules: arrival time = last_modified_date (as in the 240-minute query, since this is
about WHEN data arrived, not its clinical date). The scope is ccd, trn and lab/oru
documents only. processed/, error/ and backload/ are excluded. Times are shown in ET.
*/

WITH config AS (
    SELECT
        'hixny' AS qe,                                -- << QE (bucket name part)
        TIMESTAMP '2026-11-01 00:00:00' AS range_start,       -- << UTC; look for gaps after this
        '2026-11-17-01-00' AS snapshot_dt,                    -- << snapshot taken after the outage ended
        240 AS gap_threshold_minutes                          -- << minimum gap to report
),
cfg AS (
    SELECT c.*,
           -- Moment the snapshot was taken (dt is YYYY-MM-DD-HH-MM, in UTC).
           CAST(date_parse(c.snapshot_dt, '%Y-%m-%d-%H-%i') AS timestamp) AS snapshot_ts
    FROM config c
),

-- Every arrival in the QE's regular and Part 2 buckets, from a week before range_start
-- (needed for the "same window last week" estimate) up to the snapshot.
arrivals AS (
    SELECT
        i.bucket,
        CASE WHEN regexp_like(lower(i.key), '(^|/)ccd(/|$)') THEN 'CCD'
             WHEN regexp_like(lower(i.key), '(^|/)trn(/|$)') THEN 'TRN'
             WHEN regexp_like(lower(i.key), '(^|/)(lab|oru)(/|$)') THEN 'LAB' END AS dtype,
        i.last_modified_date AS ts
    FROM pdr_inventory.pdr_inventory_prod_data_all i
    CROSS JOIN cfg c
    WHERE i.dt = c.snapshot_dt
      AND i.bucket IN ('nyec-pdr-prod-' || c.qe, 'nyec-pdr-prod-' || c.qe || '-part2')
      AND i.is_latest = true
      AND coalesce(i.is_delete_marker, false) = false
      AND i.last_modified_date >= c.range_start - INTERVAL '7' DAY
      AND NOT regexp_like(lower(i.key), '^(processed|error)/')
      AND NOT regexp_like(lower(i.key), '(^|/)backload/')
),
typed AS (
    SELECT * FROM arrivals WHERE dtype IS NOT NULL
),

-- Distinct arrival moments per bucket (any data type), from range_start on.
moments AS (
    SELECT DISTINCT t.bucket, t.ts
    FROM typed t CROSS JOIN cfg c
    WHERE t.ts >= c.range_start
),
ordered AS (
    SELECT bucket, ts,
           lag(ts) OVER (PARTITION BY bucket ORDER BY ts) AS prev_ts
    FROM moments
),

-- Closed gaps (between two arrivals) plus an OPEN gap from the last arrival to the
-- snapshot, when the feed had not come back yet.
gaps AS (
    SELECT o.bucket, o.prev_ts AS gap_start, o.ts AS gap_end, false AS still_open
    FROM ordered o CROSS JOIN cfg c
    WHERE o.prev_ts IS NOT NULL
      AND date_diff('minute', o.prev_ts, o.ts) >= c.gap_threshold_minutes
    UNION ALL
    SELECT b.bucket, b.last_ts, c.snapshot_ts, true
    FROM (SELECT bucket, max(ts) AS last_ts FROM moments GROUP BY bucket) b
    CROSS JOIN cfg c
    WHERE date_diff('minute', b.last_ts, c.snapshot_ts) >= c.gap_threshold_minutes
),

-- Likely missing volume = the same bucket, same clock window, one week earlier.
gap_estimate AS (
    SELECT g.bucket, g.gap_start, g.gap_end, g.still_open,
           count_if(t.dtype = 'CCD') AS est_ccd,
           count_if(t.dtype = 'TRN') AS est_trn,
           count_if(t.dtype = 'LAB') AS est_lab
    FROM gaps g
    LEFT JOIN typed t
      ON t.bucket = g.bucket
     AND t.ts >= g.gap_start - INTERVAL '7' DAY
     AND t.ts <  g.gap_end   - INTERVAL '7' DAY
    GROUP BY g.bucket, g.gap_start, g.gap_end, g.still_open
),

bucket_summary AS (
    SELECT m.bucket,
           count(*) AS arrival_moments,
           max(m.ts) AS newest_ts,
           max(date_diff('minute', o.prev_ts, o.ts)) AS longest_closed_gap_min
    FROM moments m
    JOIN ordered o ON o.bucket = m.bucket AND o.ts = m.ts
    GROUP BY m.bucket
),
bucket_docs AS (
    SELECT t.bucket,
           count_if(t.dtype = 'CCD') AS ccd, count_if(t.dtype = 'TRN') AS trn, count_if(t.dtype = 'LAB') AS lab
    FROM typed t CROSS JOIN cfg c
    WHERE t.ts >= c.range_start
    GROUP BY t.bucket
)

SELECT
    'GAP' AS row_type,
    replace(e.bucket, 'nyec-pdr-prod-', '') AS bucket,
    date_format(at_timezone(with_timezone(e.gap_start, 'UTC'), 'America/New_York'), '%Y-%m-%d %H:%i') AS start_et,
    CASE WHEN e.still_open THEN 'OPEN at snapshot'
         ELSE date_format(at_timezone(with_timezone(e.gap_end, 'UTC'), 'America/New_York'), '%Y-%m-%d %H:%i') END AS end_et,
    round(date_diff('minute', e.gap_start, e.gap_end) / 60.0, 1) AS hours,
    e.est_ccd AS ccd,
    e.est_trn AS trn,
    e.est_lab AS lab,
    e.est_ccd + e.est_trn + e.est_lab AS total,
    'likely missing (same window, week before)' AS note
FROM gap_estimate e

UNION ALL

SELECT
    'BUCKET',
    replace(s.bucket, 'nyec-pdr-prod-', ''),
    date_format(at_timezone(with_timezone(c.range_start, 'UTC'), 'America/New_York'), '%Y-%m-%d %H:%i'),
    date_format(at_timezone(with_timezone(s.newest_ts, 'UTC'), 'America/New_York'), '%Y-%m-%d %H:%i'),
    round(s.longest_closed_gap_min / 60.0, 1),
    d.ccd, d.trn, d.lab, d.ccd + d.trn + d.lab,
    'arrived since range_start; end_et = newest arrival; hours = longest closed gap'
FROM bucket_summary s
JOIN bucket_docs d ON d.bucket = s.bucket
CROSS JOIN cfg c

ORDER BY row_type DESC, bucket, start_et
