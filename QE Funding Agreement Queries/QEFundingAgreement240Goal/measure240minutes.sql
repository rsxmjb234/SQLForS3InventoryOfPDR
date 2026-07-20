/*
Goal:
- Find any instance where a QE failed to submit required data to the PDR for a
  continuous 240-minute period during yesterday.

Compliance framing:
- For purposes of performance monitoring and contractual compliance, failure to
  submit any required data type to the Primary Document Repository (PDR)
  (e.g., CCD, TRN, ORU) for a continuous 240-minute period constitutes an
  outage event.

Scan-minimization choices:
- Uses dt partition key and limits to yesterday only.
- Keeps latest, non-delete-marker rows only.
- Filters key paths to required document types only.
*/

WITH params AS (
	SELECT
		date_add('day', -1, date(current_timestamp AT TIME ZONE 'America/New_York')) AS target_day,
		CAST(date_add('day', -1, date(current_timestamp AT TIME ZONE 'America/New_York')) AS timestamp) AS day_start_ts,
		CAST(date(current_timestamp AT TIME ZONE 'America/New_York') AS timestamp) AS day_end_ts,
		date_format(date_add('day', -1, date(current_timestamp AT TIME ZONE 'America/New_York')), '%Y-%m-%d-01-00') AS dt_yesterday
),
filtered AS (
	SELECT
		regexp_replace(bucket, '^nyec-pdr-prod-', '') AS bucket_short,
		regexp_replace(regexp_replace(bucket, '^nyec-pdr-prod-', ''), '-part2$', '') AS qe,
		CASE
			WHEN lower(key) LIKE 'backload/%' THEN split_part(key, '/', 2)
			ELSE split_part(key, '/', 1)
		END AS assigning_authority,
		last_modified_date AS event_ts,
		lower(key) AS key_lc
	FROM pdr_inventory.pdr_inventory_prod_data_all
	CROSS JOIN params p
	WHERE
		dt = p.dt_yesterday
		-- dt is the inventory snapshot partition, not the object submission time.
		-- Restrict event_ts to yesterday so outage windows are computed only for target_day.
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
	-- Distinct submission timestamps by QE + assigning authority for required types.
	SELECT DISTINCT
		bucket_short,
		qe,
		assigning_authority,
		event_ts
	FROM filtered
	WHERE event_ts IS NOT NULL
),
ordered_events AS (
	SELECT
		e.bucket_short,
		e.qe,
		e.assigning_authority,
		e.event_ts,
		lag(e.event_ts) OVER (
			PARTITION BY e.bucket_short, e.qe, e.assigning_authority
			ORDER BY e.event_ts
		) AS prev_event_ts
	FROM events e
),
between_event_gaps AS (
	SELECT
		p.target_day AS day,
		oe.bucket_short AS bucket,
		oe.qe,
		oe.assigning_authority,
		oe.prev_event_ts AS outage_start_ts,
		oe.event_ts AS outage_end_ts,
		date_diff('minute', oe.prev_event_ts, oe.event_ts) AS gap_minutes,
		'BETWEEN_SUBMISSIONS' AS gap_type
	FROM ordered_events oe
	CROSS JOIN params p
	WHERE oe.prev_event_ts IS NOT NULL
	  AND date_diff('minute', oe.prev_event_ts, oe.event_ts) >= 240
),
edge_gaps AS (
	SELECT
		p.target_day AS day,
		x.bucket_short AS bucket,
		x.qe,
		x.assigning_authority,
		p.day_start_ts AS outage_start_ts,
		x.first_event_ts AS outage_end_ts,
		date_diff('minute', p.day_start_ts, x.first_event_ts) AS gap_minutes,
		'DAY_START_TO_FIRST_SUBMISSION' AS gap_type
	FROM (
		SELECT
			bucket_short,
			qe,
			assigning_authority,
			min(event_ts) AS first_event_ts,
			max(event_ts) AS last_event_ts
		FROM events
		GROUP BY 1, 2, 3
	) x
	CROSS JOIN params p
	WHERE date_diff('minute', p.day_start_ts, x.first_event_ts) >= 240

	UNION ALL

	SELECT
		p.target_day AS day,
		x.bucket_short AS bucket,
		x.qe,
		x.assigning_authority,
		x.last_event_ts AS outage_start_ts,
		p.day_end_ts AS outage_end_ts,
		date_diff('minute', x.last_event_ts, p.day_end_ts) AS gap_minutes,
		'LAST_SUBMISSION_TO_DAY_END' AS gap_type
	FROM (
		SELECT
			bucket_short,
			qe,
			assigning_authority,
			min(event_ts) AS first_event_ts,
			max(event_ts) AS last_event_ts
		FROM events
		GROUP BY 1, 2, 3
	) x
	CROSS JOIN params p
	WHERE date_diff('minute', x.last_event_ts, p.day_end_ts) >= 240
)
SELECT
	day,
	bucket,
	qe,
	assigning_authority,
	outage_start_ts,
	outage_end_ts,
	gap_minutes,
	gap_type
FROM between_event_gaps
UNION ALL
SELECT
	day,
	bucket,
	qe,
	assigning_authority,
	outage_start_ts,
	outage_end_ts,
	gap_minutes,
	gap_type
FROM edge_gaps
ORDER BY day, bucket, qe, assigning_authority, outage_start_ts;
