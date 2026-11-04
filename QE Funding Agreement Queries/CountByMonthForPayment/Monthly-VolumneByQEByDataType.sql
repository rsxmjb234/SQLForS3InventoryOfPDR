
/*
Funding Agreement Requirement:

"The total volume of data submitted is expected to remain
consistent month to month. For purposes of performance
monitoring, each QE will be required to submit, at a minimum
the aggregate amount of data; NYeC will assess this using
a rolling two-month average of submitted volume, by data
type, as the 'baseline.'

If, for a full calendar month, a QE's submitted volume
is more than 10% below its baseline, and the variance
is not attributable to expected changes, the variance
will be considered a PDR outage."

Purpose:
- Monthly document count by QE and data type.
- Exclude backload data.
- Include only Verato-matched assigning authorities.
- Calculate rolling two-month volume baselines.
- Flag volumes more than 10% below baseline.

CORRECTION:
Prior to August 28, 2026, PDR processing used
processed/ and error/ workflow prefixes.

Historical objects were subsequently copied back to
their original root paths.

The S3 inventory therefore contains multiple physical
objects representing the same logical document key.

This query normalizes workflow prefixes and deduplicates
by (bucket, canonical_key) before calculating monthly
document counts.

The final output format remains unchanged.
*/

WITH config AS (
    SELECT
        DATE '2026-01-01' AS start_month,
        DATE '2026-10-01' AS end_month,
        '2026-11-01-01-00' AS single_snapshot_dt
),

-- Map PDR bucket QE names to Verato QE names.
qe_name_map AS (
    SELECT pdr_name, verato_name
    FROM (VALUES
        ('bronx', 'BRONX'),
        ('rochester', 'GRRHIO'),
        ('healtheconnections', 'HECDCS'),
        ('healthix', 'HEALTHIX'),
        ('hixny', 'HIXNY'),
        ('techbd', 'TXD'),
        ('healthelink', 'HEALTHELINK')
    ) AS t(pdr_name, verato_name)
),

-- Normalize Verato assigning authorities.
verato_norm AS (
    SELECT DISTINCT
        lower(m.pdr_name) AS pdr_qe,

        upper(
            CASE
                WHEN upper(m.verato_name) = 'BRONX'
                THEN replace(
                    regexp_replace(
                        v.assigning_authority,
                        '\.(DUPLICATE|DUPLICATE1|DUPLICATE2|DUPLICATE3)$',
                        ''
                    ),
                    '_', ' '
                )
                ELSE regexp_replace(
                    v.assigning_authority,
                    '\.(DUPLICATE|DUPLICATE1|DUPLICATE2|DUPLICATE3)$',
                    ''
                )
            END
        ) AS aa_key

    FROM pdr_inventory.lookup_verato_aa v

    JOIN qe_name_map m
        ON upper(v.qe) = upper(m.verato_name)
),

-- Read documents from a single S3 inventory snapshot.
-- Submission dates are derived from the S3 key path,
-- not from last_modified_date.
pdr_docs AS (
    SELECT
        date_format(submission_date, '%Y-%m') AS month,

        date_trunc('month', submission_date) AS month_start,

        bucket,
        canonical_key,
        qe,
        assigning_authority,
        data_type

    FROM (
        SELECT
            i.bucket,

            -- CORRECTION:
            -- Normalize workflow prefixes to the original key.
            --
            -- processed/AA/ccd/... -> AA/ccd/...
            -- error/AA/ccd/...     -> AA/ccd/...
            -- AA/ccd/...           -> AA/ccd/...
            regexp_replace(
                i.key,
                '(?i)^(processed|error)/',
                ''
            ) AS canonical_key,

            regexp_replace(
                regexp_replace(
                    i.bucket,
                    '^nyec-pdr-prod-',
                    ''
                ),
                '-part2$',
                ''
            ) AS qe,

            upper(trim(
                CASE
                    WHEN lower(split_part(i.key, '/', 1))
                         IN ('processed', 'error', 'backload')
                    THEN split_part(i.key, '/', 2)
                    ELSE split_part(i.key, '/', 1)
                END
            )) AS assigning_authority,

            CASE
                WHEN regexp_like(
                    lower(i.key),
                    '(^|/)ccd(/|$)'
                ) THEN 'CCD'

                WHEN regexp_like(
                    lower(i.key),
                    '(^|/)trn(/|$)'
                ) THEN 'TRN'

                WHEN regexp_like(
                    lower(i.key),
                    '(^|/)oru(/|$)'
                ) THEN 'ORU'

                WHEN regexp_like(
                    lower(i.key),
                    '(^|/)lab(/|$)'
                ) THEN 'LAB'
            END AS data_type,

            TRY(date_parse(
                regexp_extract(
                    i.key,
                    '(?i)(?:ccd|trn|lab|oru)/(\d{4}/[A-Za-z]{3}/\d{2})/',
                    1
                ),
                '%Y/%b/%d'
            )) AS submission_date

        FROM pdr_inventory.pdr_inventory_prod_data_all i

        CROSS JOIN config c

        WHERE
            i.dt = c.single_snapshot_dt

            AND i.bucket LIKE 'nyec-pdr-prod-%'

            AND i.is_latest = true

            AND coalesce(
                i.is_delete_marker,
                false
            ) = false

            -- Existing scan reducer.
            AND i.last_modified_date >=
                timestamp '2026-03-11 00:00:00'

            -- Exclude backload.
            AND NOT regexp_like(
                lower(i.key),
                '(^|/)backload/'
            )

            -- Only recognized document types.
            AND (
                regexp_like(
                    lower(i.key),
                    '(^|/)ccd(/|$)'
                )
                OR regexp_like(
                    lower(i.key),
                    '(^|/)trn(/|$)'
                )
                OR regexp_like(
                    lower(i.key),
                    '(^|/)oru(/|$)'
                )
                OR regexp_like(
                    lower(i.key),
                    '(^|/)lab(/|$)'
                )
            )
    ) t

    CROSS JOIN config c

    WHERE
        submission_date IS NOT NULL

        -- Clinical-data floor.
        AND submission_date >= DATE '2026-03-11'

        -- Reporting window.
        AND submission_date >= c.start_month

        AND submission_date <
            date_add('month', 1, c.end_month)
),

-- CORRECTION:
-- Apply Verato matching, then eliminate duplicate
-- physical objects representing the same document.
--
-- The combination of bucket and canonical_key
-- uniquely identifies the normalized S3 object.
eligible_docs AS (
    SELECT DISTINCT
        d.month,
        d.month_start,
        d.qe,
        d.data_type,
        d.bucket,
        d.canonical_key

    FROM pdr_docs d

    JOIN verato_norm vn
        ON lower(d.qe) = vn.pdr_qe
       AND d.assigning_authority = vn.aa_key

    WHERE d.data_type IS NOT NULL
),

-- Count canonical documents, not physical S3 objects.
monthly_raw AS (
    SELECT
        month,
        month_start,
        qe,
        data_type,
        count(*) AS doc_count

    FROM eligible_docs

    GROUP BY 1, 2, 3, 4
),

-- Original rolling two-month baseline calculation.
with_baseline AS (
    SELECT
        month,
        qe,
        data_type,
        doc_count,

        CAST(
            round(
                avg(doc_count) OVER (
                    PARTITION BY qe, data_type
                    ORDER BY month_start
                    ROWS BETWEEN
                        2 PRECEDING AND 1 PRECEDING
                )
            ) AS bigint
        ) AS rolling_2mo_avg

    FROM monthly_raw
)

-- Original output columns and ordering preserved.
SELECT
    month,
    qe,
    data_type,
    doc_count,
    rolling_2mo_avg,

    CASE
        WHEN rolling_2mo_avg IS NULL
          OR rolling_2mo_avg = 0
        THEN NULL

        ELSE CAST(
            round(
                100.0 * doc_count / rolling_2mo_avg
            ) AS bigint
        )
    END AS pct_of_baseline,

    CASE
        WHEN rolling_2mo_avg IS NULL
          OR rolling_2mo_avg = 0
        THEN 'N/A'

        WHEN doc_count < (rolling_2mo_avg * 0.9)
        THEN 'YES'

        ELSE 'NO'
    END AS below_10pct_flag

FROM with_baseline

ORDER BY
    qe ASC,
    data_type ASC,
    month ASC;
