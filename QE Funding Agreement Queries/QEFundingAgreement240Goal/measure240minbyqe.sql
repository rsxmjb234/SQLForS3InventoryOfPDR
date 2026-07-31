/*
Goal:
- Find any instance where a QE failed to submit required data to the PDR
	for a continuous 240-minute period during each day in the target date range.
- Measured at the QE level (not per assigning authority / source).
- A gap anywhere across any submission from the QE counts as an outage.

Compliance framing:
- For purposes of performance monitoring and contractual compliance, failure to
  submit any required data type to the Primary Document Repository (PDR)
  (e.g., CCD, TRN, ORU) for a continuous 240-minute period constitutes an
  outage event.

Why end at today - 2 days instead of yesterday:
- The S3 inventory job runs once daily and produces a snapshot of all objects
  with their last_modified_date at the time the job ran (typically ~1-4 AM UTC).
- If we target yesterday, the inventory snapshot may not yet be complete,
  causing the query to report false outages for the remainder of the day.
- Using today - 2 days for the end date ensures the inventory job has fully run
	and each selected day has a complete picture of submissions.

Scan-minimization choices:
- Uses dt partition key and limits to each generated target day only.
- Keeps latest, non-delete-marker rows only.
- Filters key paths to required document types only.
*/

WITH config AS (
	SELECT
		CAST(DATE '2017-07-01' AS date) AS start_date, -- # start date (example: 06/01/2017)
		date_add('day', -2, date(current_timestamp AT TIME ZONE 'America/New_York')) AS end_date, -- # end date (last full inventory day)
		2 AS inventory_snapshot_offset_days, -- # snapshot lag from event day to inventory dt partition
		240 AS outage_threshold_minutes -- # outage threshold in minutes
		-- # Use 1 for next-day snapshot; use 2 if inventory delivery is delayed.
),
day_params AS (
	SELECT
		d.target_day,
		c.inventory_snapshot_offset_days,
		c.outage_threshold_minutes,
		CAST(d.target_day AS timestamp) AS day_start_ts,
		CAST(date_add('day', 1, d.target_day) AS timestamp) AS day_end_ts,
		date_format(
			date_add('day', c.inventory_snapshot_offset_days, d.target_day),
			'%Y-%m-%d-01-00'
		) AS dt_target_partition
		-- start/end control the analysis window; snapshot offset controls which inventory run to read.
	FROM config c
	CROSS JOIN UNNEST(sequence(c.start_date, c.end_date, INTERVAL '1' day)) AS d(target_day)
),
filtered AS (
	SELECT
		dp.target_day,
		regexp_replace(regexp_replace(bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS qe,
		last_modified_date AS event_ts
	FROM pdr_inventory.pdr_inventory_prod_data_all
	JOIN day_params dp
		ON dt = dp.dt_target_partition
	WHERE
		-- dt is the inventory snapshot partition, not the object submission time.
		-- Restrict event_ts to each generated target_day so outage windows are day-scoped.
		last_modified_date >= dp.day_start_ts
		AND last_modified_date < dp.day_end_ts
		-- Optional additional partition pruning (uncomment and fill real values):
		-- AND inventory_source IN ('real-source-1', 'real-source-2')
		AND bucket LIKE 'nyec-pdr-prod-%'
		AND is_latest = true
		AND coalesce(is_delete_marker, false) = false
		AND (
			regexp_like(lower(key), '(^|/)ccd(/|$)')
			OR regexp_like(lower(key), '(^|/)trn(/|$)')
			OR regexp_like(lower(key), '(^|/)oru(/|$)')
		)
),
events AS (
	-- Distinct submission timestamps per QE per target day.
	SELECT DISTINCT
		target_day,
		qe,
		event_ts
	FROM filtered
	WHERE event_ts IS NOT NULL
),
ordered_events AS (
	SELECT
		e.target_day,
		e.qe,
		e.event_ts,
		lag(e.event_ts) OVER (
			PARTITION BY e.target_day, e.qe
			ORDER BY e.event_ts
		) AS prev_event_ts
	FROM events e
),
between_event_gaps AS (
	SELECT
		oe.target_day AS day,
		oe.qe,
		oe.prev_event_ts AS outage_start_ts,
		oe.event_ts AS outage_end_ts,
		date_diff('minute', oe.prev_event_ts, oe.event_ts) AS gap_minutes,
		'BETWEEN_SUBMISSIONS' AS gap_type
	FROM ordered_events oe
	JOIN day_params dp
		ON oe.target_day = dp.target_day
	WHERE oe.prev_event_ts IS NOT NULL
	  AND date_diff('minute', oe.prev_event_ts, oe.event_ts) >= dp.outage_threshold_minutes
),
edge_gaps AS (
	SELECT
		x.target_day AS day,
		x.qe,
		dp.day_start_ts AS outage_start_ts,
		x.first_event_ts AS outage_end_ts,
		date_diff('minute', dp.day_start_ts, x.first_event_ts) AS gap_minutes,
		'DAY_START_TO_FIRST_SUBMISSION' AS gap_type
	FROM (
		SELECT
			target_day,
			qe,
			min(event_ts) AS first_event_ts,
			max(event_ts) AS last_event_ts
		FROM events
		GROUP BY 1, 2
	) x
	JOIN day_params dp
		ON x.target_day = dp.target_day
	WHERE date_diff('minute', dp.day_start_ts, x.first_event_ts) >= dp.outage_threshold_minutes

	UNION ALL

	SELECT
		x.target_day AS day,
		x.qe,
		x.last_event_ts AS outage_start_ts,
		dp.day_end_ts AS outage_end_ts,
		date_diff('minute', x.last_event_ts, dp.day_end_ts) AS gap_minutes,
		'LAST_SUBMISSION_TO_DAY_END' AS gap_type
	FROM (
		SELECT
			target_day,
			qe,
			min(event_ts) AS first_event_ts,
			max(event_ts) AS last_event_ts
		FROM events
		GROUP BY 1, 2
	) x
	JOIN day_params dp
		ON x.target_day = dp.target_day
	WHERE date_diff('minute', x.last_event_ts, dp.day_end_ts) >= dp.outage_threshold_minutes
)
SELECT
	day,
	qe,
	date_format(at_timezone(with_timezone(outage_start_ts, 'UTC'), 'America/New_York'), '%Y-%m-%d %H:%i') AS outage_start_ts,
	date_format(at_timezone(with_timezone(outage_end_ts, 'UTC'), 'America/New_York'), '%Y-%m-%d %H:%i') AS outage_end_ts,
	gap_minutes,
	gap_type
FROM between_event_gaps
UNION ALL
SELECT
	day,
	qe,
	date_format(at_timezone(with_timezone(outage_start_ts, 'UTC'), 'America/New_York'), '%Y-%m-%d %H:%i') AS outage_start_ts,
	date_format(at_timezone(with_timezone(outage_end_ts, 'UTC'), 'America/New_York'), '%Y-%m-%d %H:%i') AS outage_end_ts,
	gap_minutes,
	gap_type
FROM edge_gaps
ORDER BY day, qe, outage_start_ts;
