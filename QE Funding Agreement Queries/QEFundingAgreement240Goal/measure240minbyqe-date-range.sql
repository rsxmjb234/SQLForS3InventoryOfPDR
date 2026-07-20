/*
Expected cost/run (full month): ~$2.45 (490.85 GB scanned @ $5/TB)
Expected runtime: ~1.5 minutes

Goal:
- Find QE-level outage events over a date range.
- An outage is any continuous gap with no required submissions for at least
  outage_threshold_minutes.

How to use:
- Set start_day and end_day in config.
- Keep outage_threshold_minutes configurable (for example 240).
- inventory_snapshot_offset_days controls which inventory run partition is used
  for each target day. Use 1 for next-day snapshot, or 2 if delivery is delayed.
*/

WITH config AS (
	SELECT
		DATE '2026-06-01' AS start_day,
		date_add('day', -1, date(current_timestamp AT TIME ZONE 'America/New_York')) AS end_day,
		2 AS inventory_snapshot_offset_days,
		240 AS outage_threshold_minutes
),
days AS (
	SELECT
		d AS target_day
	FROM config c
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
		) AS dt_target_partition,
		c.outage_threshold_minutes
	FROM days d
	CROSS JOIN config c
),
filtered AS (
	SELECT
		p.target_day AS day,
		regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS qe,
		i.last_modified_date AS event_ts
	FROM pdr_inventory.pdr_inventory_prod_data_all i
	JOIN params p
		ON i.dt = p.dt_target_partition
		AND i.last_modified_date >= p.day_start_ts
		AND i.last_modified_date < p.day_end_ts
	WHERE
		i.bucket LIKE 'nyec-pdr-prod-%'
		AND i.is_latest = true
		AND coalesce(i.is_delete_marker, false) = false
		AND (
			regexp_like(lower(i.key), '(^|/)ccd(/|$)')
			OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
			OR regexp_like(lower(i.key), '(^|/)oru(/|$)')
		)
),
events AS (
	SELECT DISTINCT
		day,
		qe,
		event_ts
	FROM filtered
	WHERE event_ts IS NOT NULL
),
ordered_events AS (
	SELECT
		e.day,
		e.qe,
		e.event_ts,
		lag(e.event_ts) OVER (
			PARTITION BY e.day, e.qe
			ORDER BY e.event_ts
		) AS prev_event_ts
	FROM events e
),
between_event_gaps AS (
	SELECT
		oe.day,
		oe.qe,
		oe.prev_event_ts AS outage_start_ts,
		oe.event_ts AS outage_end_ts,
		date_diff('minute', oe.prev_event_ts, oe.event_ts) AS gap_minutes,
		'BETWEEN_SUBMISSIONS' AS gap_type
	FROM ordered_events oe
	JOIN params p
		ON p.target_day = oe.day
	WHERE oe.prev_event_ts IS NOT NULL
	  AND date_diff('minute', oe.prev_event_ts, oe.event_ts) >= p.outage_threshold_minutes
),
edge_summary AS (
	SELECT
		day,
		qe,
		min(event_ts) AS first_event_ts,
		max(event_ts) AS last_event_ts
	FROM events
	GROUP BY 1, 2
),
edge_gaps AS (
	SELECT
		x.day,
		x.qe,
		p.day_start_ts AS outage_start_ts,
		x.first_event_ts AS outage_end_ts,
		date_diff('minute', p.day_start_ts, x.first_event_ts) AS gap_minutes,
		'DAY_START_TO_FIRST_SUBMISSION' AS gap_type
	FROM edge_summary x
	JOIN params p
		ON p.target_day = x.day
	WHERE date_diff('minute', p.day_start_ts, x.first_event_ts) >= p.outage_threshold_minutes

	UNION ALL

	SELECT
		x.day,
		x.qe,
		x.last_event_ts AS outage_start_ts,
		p.day_end_ts AS outage_end_ts,
		date_diff('minute', x.last_event_ts, p.day_end_ts) AS gap_minutes,
		'LAST_SUBMISSION_TO_DAY_END' AS gap_type
	FROM edge_summary x
	JOIN params p
		ON p.target_day = x.day
	WHERE date_diff('minute', x.last_event_ts, p.day_end_ts) >= p.outage_threshold_minutes
)
SELECT
	date_format(day, '%Y-%m-%d') AS day,
	CASE
		WHEN day_of_week(day) IN (6, 7) THEN 'weekend'
		ELSE 'Weekday'
	END AS day_type,
	qe,
	date_format(at_timezone(with_timezone(outage_start_ts, 'UTC'), 'America/New_York'), '%Y-%m-%d %H:%i') AS outage_start_ts,
	date_format(at_timezone(with_timezone(outage_end_ts, 'UTC'), 'America/New_York'), '%Y-%m-%d %H:%i') AS outage_end_ts,
	gap_minutes,
	gap_type
FROM between_event_gaps
UNION ALL
SELECT
	date_format(day, '%Y-%m-%d') AS day,
	CASE
		WHEN day_of_week(day) IN (6, 7) THEN 'weekend'
		ELSE 'Weekday'
	END AS day_type,
	qe,
	date_format(at_timezone(with_timezone(outage_start_ts, 'UTC'), 'America/New_York'), '%Y-%m-%d %H:%i') AS outage_start_ts,
	date_format(at_timezone(with_timezone(outage_end_ts, 'UTC'), 'America/New_York'), '%Y-%m-%d %H:%i') AS outage_end_ts,
	gap_minutes,
	gap_type
FROM edge_gaps
ORDER BY day, qe, outage_start_ts;
