WITH params AS (
    SELECT
        current_date AS run_date,
        date_add('day', -4, current_date) AS recent_snapshot_date,
        date_add('day', -14, current_date) AS comparison_snapshot_date,
        10 AS comparison_window_days
),
partitions AS (
    SELECT
        run_date,
        recent_snapshot_date,
        comparison_snapshot_date,
        comparison_window_days,
        date_format(recent_snapshot_date, '%Y-%m-%d-01-00') AS recent_dt,
        date_format(comparison_snapshot_date, '%Y-%m-%d-01-00') AS comparison_dt
    FROM params
),
qe_name_map AS (
    SELECT pdr_name, verato_name
    FROM (VALUES
        ('bronx',              'BRONX'),
        ('rochester',          'GRRHIO'),
        ('healtheconnections', 'HECDCS'),
        ('healthix',           'HEALTHIX'),
        ('hixny',              'HIXNY'),
        ('techbd',             'TXD'),
        ('healthelink',        'HEALTHELINK')
    ) AS t(pdr_name, verato_name)
),
verato_norm AS (
    SELECT DISTINCT
        lower(m.pdr_name) AS pdr_qe,
        upper(
            CASE
                WHEN upper(m.verato_name) = 'BRONX'
                THEN replace(regexp_replace(v.assigning_authority,
                        '\.(DUPLICATE|DUPLICATE1|DUPLICATE2|DUPLICATE3)$', ''), '_', ' ')
                ELSE regexp_replace(v.assigning_authority,
                        '\.(DUPLICATE|DUPLICATE1|DUPLICATE2|DUPLICATE3)$', '')
            END
        ) AS aa_key
    FROM pdr_inventory.lookup_verato_aa v
    JOIN qe_name_map m
        ON upper(v.qe) = upper(m.verato_name)
),
documents AS (
    SELECT
        CASE WHEN i.dt = p.recent_dt THEN 'RECENT' ELSE 'COMPARISON' END AS snapshot_name,
        CASE
            WHEN regexp_like(lower(i.key), '(^|/)backload(/|$)') THEN 'BACKLOG'
            ELSE 'REAL-TIME'
        END AS load_type,
        lower(regexp_replace(regexp_replace(i.bucket, '^nyec-pdr-prod-', ''), '-part2$', '')) AS qe,
        upper(trim(
            CASE
                WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error', 'backload')
                THEN split_part(i.key, '/', 2)
                ELSE split_part(i.key, '/', 1)
            END
        )) AS aa_key,
        CASE
            WHEN regexp_like(lower(i.key), '(^|/)ccd(/|$)') THEN 'CCD'
            WHEN regexp_like(lower(i.key), '(^|/)trn(/|$)') THEN 'TRN'
            WHEN regexp_like(lower(i.key), '(^|/)lab(/|$)') THEN 'LAB'
        END AS doc_type,
        i.size AS size_bytes,
        i.last_modified_date AS arrival_timestamp
    FROM pdr_inventory.pdr_inventory_prod_data_all i
    CROSS JOIN partitions p
    WHERE i.dt IN (p.recent_dt, p.comparison_dt)
        AND i.bucket LIKE 'nyec-pdr-prod-%'
        AND i.is_latest = true
        AND coalesce(i.is_delete_marker, false) = false
        AND i.last_modified_date >= timestamp '2026-03-11 00:00:00'
        AND (
            regexp_like(lower(i.key), '(^|/)ccd(/|$)')
            OR regexp_like(lower(i.key), '(^|/)trn(/|$)')
            OR regexp_like(lower(i.key), '(^|/)lab(/|$)')
        )
),
valid_documents AS (
    SELECT d.*
    FROM documents d
    JOIN verato_norm v
        ON d.qe = v.pdr_qe
        AND d.aa_key = v.aa_key
    WHERE d.doc_type IS NOT NULL
),
grouped AS (
    SELECT
        qe,
        doc_type,
        load_type,
        count_if(snapshot_name = 'RECENT') AS recent_document_count,
        count_if(snapshot_name = 'COMPARISON') AS comparison_document_count,
        sum(CASE WHEN snapshot_name = 'RECENT' THEN size_bytes ELSE 0 END) AS recent_total_size_bytes,
        avg(CASE WHEN snapshot_name = 'RECENT' THEN size_bytes END) AS recent_average_size_bytes,
        sum(CASE WHEN snapshot_name = 'COMPARISON' THEN size_bytes ELSE 0 END) AS comparison_total_size_bytes,
        avg(CASE WHEN snapshot_name = 'COMPARISON' THEN size_bytes END) AS comparison_average_size_bytes,
        min(CASE WHEN snapshot_name = 'RECENT' THEN CAST(arrival_timestamp AS date) END) AS recent_first_arrival_date,
        max(CASE WHEN snapshot_name = 'RECENT' THEN CAST(arrival_timestamp AS date) END) AS recent_last_arrival_date,
        count_if(
            snapshot_name = 'RECENT'
            AND load_type = 'BACKLOG'
            AND CAST(arrival_timestamp AS date) BETWEEN
                date_add('day', -2, (SELECT recent_snapshot_date FROM params))
                AND (SELECT recent_snapshot_date FROM params)
        ) AS recent_arrivals_last_3_days
    FROM valid_documents
    GROUP BY qe, doc_type, load_type
),
dimensions AS (
    SELECT lower(pdr_name) AS qe, doc_type, load_type
    FROM qe_name_map
    CROSS JOIN (VALUES ('CCD'), ('TRN'), ('LAB')) AS d(doc_type)
    CROSS JOIN (VALUES ('REAL-TIME'), ('BACKLOG')) AS l(load_type)
),
arrival_summary AS (
    SELECT
        min(CASE WHEN load_type = 'BACKLOG' THEN CAST(arrival_timestamp AS date) END) AS first_backlog_arrival_date,
        max(CASE WHEN load_type = 'BACKLOG' THEN CAST(arrival_timestamp AS date) END) AS last_backlog_arrival_date,
        count_if(
            load_type = 'BACKLOG'
            AND CAST(arrival_timestamp AS date) BETWEEN
                date_add('day', -2, (SELECT recent_snapshot_date FROM params))
                AND (SELECT recent_snapshot_date FROM params)
        ) AS backlog_arrivals_last_3_days,
        min(CASE WHEN doc_type = 'LAB' THEN CAST(arrival_timestamp AS date) END) AS first_lab_arrival_date
    FROM valid_documents
    WHERE snapshot_name = 'RECENT'
),
report AS (
    SELECT
        p.run_date,
        p.recent_snapshot_date,
        p.recent_dt,
        p.comparison_snapshot_date,
        p.comparison_dt,
        p.comparison_window_days,
        d.qe,
        d.doc_type,
        d.load_type,
        coalesce(g.recent_document_count, 0) AS recent_document_count,
        coalesce(g.comparison_document_count, 0) AS comparison_document_count,
        coalesce(g.recent_total_size_bytes, 0) AS recent_total_size_bytes,
        g.recent_average_size_bytes,
        coalesce(g.comparison_total_size_bytes, 0) AS comparison_total_size_bytes,
        g.comparison_average_size_bytes,
        g.recent_first_arrival_date,
        g.recent_last_arrival_date,
        CASE
            WHEN d.load_type = 'BACKLOG' THEN coalesce(g.recent_arrivals_last_3_days, 0)
        END AS recent_arrivals_last_3_days,
        a.first_backlog_arrival_date,
        a.last_backlog_arrival_date,
        a.backlog_arrivals_last_3_days,
        a.first_lab_arrival_date
    FROM dimensions d
    CROSS JOIN partitions p
    CROSS JOIN arrival_summary a
    LEFT JOIN grouped g
        ON d.qe = g.qe
        AND d.doc_type = g.doc_type
        AND d.load_type = g.load_type
)

SELECT *
FROM report
ORDER BY qe, doc_type, load_type;