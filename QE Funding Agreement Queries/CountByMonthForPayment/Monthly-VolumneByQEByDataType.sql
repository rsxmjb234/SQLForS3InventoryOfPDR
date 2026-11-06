
/*
PDR Monthly Volume Report
Updated November 2026

Corrections:

1. Historical processed/ and error/ S3 objects
   were copied back to their original root paths.
   Normalize these prefixes and deduplicate by
   bucket + canonical key.

2. Verato-only filtering (NYeC decision, Nov 2026).

   Include a document ONLY when its AA exists in
   the Verato export (lookup_verato_aa). Any
   source not in Verato is excluded.

   Dan's PR proposed also counting pre-Oct 7
   unmapped sources, minus known aliases from a
   PDR AA mapping table. That table
   (lookup_pdr_aa_mapping) does not exist in
   Athena, and the Verato-only rule already
   handles this, so that branch was removed.

3. Preserve the original reporting output:
   month, qe, data_type, doc_count,
   rolling_2mo_avg, pct_of_baseline,
   below_10pct_flag.
*/

WITH config AS (
    SELECT
        DATE '2026-01-01' AS start_month,
        DATE '2026-10-01' AS end_month,
        -- Single recent, complete snapshot partition to read from.
        date_format(date_add('day', -2, current_date), '%Y-%m-%d-01-00') AS single_snapshot_dt
),

-- Map PDR QE names to Verato QE names.
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

        upper(trim(
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
        )) AS aa_key

    FROM pdr_inventory.lookup_verato_aa v

    JOIN qe_name_map m
        ON upper(trim(v.qe)) = upper(m.verato_name)
),

-- Read one S3 inventory snapshot.
-- Normalize historical workflow paths.
inventory AS (
    SELECT
        i.bucket,

        regexp_replace(
            regexp_replace(
                i.bucket,
                '^nyec-pdr-prod-',
                ''
            ),
            '-part2$',
            ''
        ) AS qe,

        -- Remove the historical workflow prefix.
        --
        -- processed/AA/ccd/... -> AA/ccd/...
        -- error/AA/ccd/...     -> AA/ccd/...
        -- AA/ccd/...           -> AA/ccd/...
        regexp_replace(
            i.key,
            '(?i)^(processed|error)/',
            ''
        ) AS canonical_key

    FROM pdr_inventory.pdr_inventory_prod_data_all i

    CROSS JOIN config c

    WHERE i.dt = c.single_snapshot_dt

      AND i.bucket LIKE 'nyec-pdr-prod-%'

      AND i.is_latest = true

      AND coalesce(
          i.is_delete_marker,
          false
      ) = false

      -- Preserve Michael's original scan reducer.
      AND i.last_modified_date >=
          timestamp '2026-03-11 00:00:00'

      -- Exclude backload documents.
      AND NOT regexp_like(
          lower(i.key),
          '(^|/)backload/'
      )

      -- Recognized document types only.
      AND (
          regexp_like(
              lower(i.key), '(^|/)ccd(/|$)'
          )
          OR regexp_like(
              lower(i.key), '(^|/)trn(/|$)'
          )
          OR regexp_like(
              lower(i.key), '(^|/)oru(/|$)'
          )
          OR regexp_like(
              lower(i.key), '(^|/)lab(/|$)'
          )
      )
),

-- Extract the assigning authority, document type,
-- and submission date from the canonical path.
parsed AS (
    SELECT
        bucket,
        qe,
        canonical_key,

        upper(trim(
            split_part(canonical_key, '/', 1)
        )) AS assigning_authority,

        CASE
            WHEN regexp_like(
                lower(canonical_key),
                '(^|/)ccd(/|$)'
            ) THEN 'CCD'

            WHEN regexp_like(
                lower(canonical_key),
                '(^|/)trn(/|$)'
            ) THEN 'TRN'

            WHEN regexp_like(
                lower(canonical_key),
                '(^|/)oru(/|$)'
            ) THEN 'ORU'

            WHEN regexp_like(
                lower(canonical_key),
                '(^|/)lab(/|$)'
            ) THEN 'LAB'
        END AS data_type,

        -- Submission date is derived from the
        -- S3 key path, not last_modified_date.
        CAST(TRY(date_parse(
            regexp_extract(
                canonical_key,
                '(?i)(?:ccd|trn|lab|oru)/(\d{4}/[A-Za-z]{3}/\d{2})/',
                1
            ),
            '%Y/%b/%d'
        )) AS date) AS submission_day

    FROM inventory
),

-- Apply Verato eligibility.
--
-- Only sources present in the Verato export are
-- counted (inner join). Sources not in Verato
-- (orphans) are excluded.
eligible_docs AS (
    SELECT DISTINCT
        p.bucket,
        p.canonical_key,
        p.qe,
        p.data_type,

        CAST(
            date_trunc('month', p.submission_day)
            AS date
        ) AS month_start

    FROM parsed p

    CROSS JOIN config c

    JOIN verato_norm v
        ON p.qe = v.pdr_qe
       AND p.assigning_authority = v.aa_key

    WHERE p.submission_day IS NOT NULL

      AND p.submission_day >= DATE '2026-03-11'

      AND p.submission_day >= c.start_month

      AND p.submission_day <
          date_add('month', 1, c.end_month)

      AND p.data_type IS NOT NULL
),

-- Count each canonical object once per bucket.
-- DISTINCT was applied in eligible_docs.
monthly_raw AS (
    SELECT
        date_format(
            CAST(month_start AS timestamp),
            '%Y-%m'
        ) AS month,

        month_start,
        qe,
        data_type,

        count(*) AS doc_count

    FROM eligible_docs

    GROUP BY
        month_start,
        qe,
        data_type
),

-- Original rolling two-month average.
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

-- Preserve Michael's original output format.
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
