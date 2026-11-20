import athena_hello_world as a

a.TIMEOUT_SECONDS = 1500
snap, _ = a.athena_query("SELECT max(dt) AS dt FROM pdr_inventory.pdr_inventory_prod_data_all WHERE dt >= '2026-11-10'")
dt = snap[0]["dt"]
print("snapshot:", dt)

# Arrival time = last_modified (same as the 240 query). Any data type, any file
# under the normal paths (processed/, error/, backload/ excluded). Units: each bucket on
# its own, and each QE (regular + part2 combined). Includes the open gap from the last
# arrival to the snapshot time.
sql = f"""
WITH c AS (
    SELECT CAST(date_parse('{dt}', '%Y-%m-%d-%H-%i') AS timestamp) AS snap_ts
),
ev AS (
    SELECT DISTINCT i.bucket, i.last_modified_date AS ts
    FROM pdr_inventory.pdr_inventory_prod_data_all i CROSS JOIN c
    WHERE i.dt = '{dt}'
      AND i.bucket LIKE 'nyec-pdr-prod-%'
      AND i.is_latest = true AND coalesce(i.is_delete_marker, false) = false
      AND i.last_modified_date >= c.snap_ts - INTERVAL '10' DAY
      AND i.last_modified_date <  c.snap_ts
      AND lower(split_part(i.key, '/', 1)) NOT IN ('processed', 'error')
      AND NOT regexp_like(lower(i.key), '(^|/)backload/')
),
units AS (
    SELECT replace(bucket, 'nyec-pdr-prod-', '') AS unit, 'bucket' AS level, ts FROM ev
    UNION ALL
    SELECT DISTINCT regexp_replace(replace(bucket, 'nyec-pdr-prod-', ''), '-part2$', ''), 'qe', ts FROM ev
),
o AS (
    SELECT unit, level, ts, lag(ts) OVER (PARTITION BY unit, level ORDER BY ts) AS prev FROM units
),
g AS (
    SELECT unit, level, prev AS gs, ts AS ge, date_diff('minute', prev, ts) AS m FROM o WHERE prev IS NOT NULL
    UNION ALL
    SELECT u.unit, u.level, max(u.ts), c.snap_ts, date_diff('minute', max(u.ts), c.snap_ts)
    FROM units u CROSS JOIN c GROUP BY u.unit, u.level, c.snap_ts
),
r AS (
    SELECT *, row_number() OVER (PARTITION BY unit, level ORDER BY m DESC) AS rn FROM g
)
SELECT level, unit, rn, m AS minutes,
       date_format(at_timezone(with_timezone(gs, 'UTC'), 'America/New_York'), '%a %m-%d %H:%i') AS start_et,
       date_format(at_timezone(with_timezone(ge, 'UTC'), 'America/New_York'), '%a %m-%d %H:%i') AS end_et,
       (SELECT count_if(m >= 30) FROM g g2 WHERE g2.unit = r.unit AND g2.level = r.level) AS gaps_30m,
       (SELECT count_if(m >= 60) FROM g g2 WHERE g2.unit = r.unit AND g2.level = r.level) AS gaps_60m,
       (SELECT count_if(m >= 120) FROM g g2 WHERE g2.unit = r.unit AND g2.level = r.level) AS gaps_120m
FROM r
WHERE rn <= 3
ORDER BY level, unit, rn
"""
rows, b = a.athena_query(sql)
print(f"scanned {b / 1e9:.1f} GB")
print(f"{'level':<7}{'unit':<26}{'#':>2}{'minutes':>9}  {'start ET':<16}{'end ET':<16}{'>=30m':>6}{'>=60m':>6}{'>=2h':>6}")
for r in rows:
    print(f"{r['level']:<7}{r['unit']:<26}{r['rn']:>2}{int(r['minutes']):>9,}  {r['start_et']:<16}{r['end_et']:<16}"
          f"{r['gaps_30m'] if r['rn'] == '1' else '':>6}{r['gaps_60m'] if r['rn'] == '1' else '':>6}{r['gaps_120m'] if r['rn'] == '1' else '':>6}")
