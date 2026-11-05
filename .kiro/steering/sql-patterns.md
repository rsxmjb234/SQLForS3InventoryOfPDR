---
inclusion: auto
---

# SQL Query Patterns for PDR Inventory

## Extracting Assigning Authority from S3 Keys

S3 keys in the PDR inventory can have these prefix structures:
- `processed/AssigningAuthority/doctype/...` — successfully processed docs
- `error/AssigningAuthority/doctype/...` — docs that errored during processing
- `backload/AssigningAuthority/doctype/...` — backlog data
- `AssigningAuthority/doctype/...` — normal/direct path

**ALWAYS** use this pattern to extract the assigning authority:

```sql
CASE
    WHEN lower(split_part(i.key, '/', 1)) IN ('processed', 'error', 'backload')
    THEN split_part(i.key, '/', 2)
    ELSE split_part(i.key, '/', 1)
END AS assigning_authority
```

**NEVER** use the old pattern that only checks for `backload`:
```sql
-- WRONG - misses processed/ and error/ prefixes
CASE
    WHEN lower(i.key) LIKE 'backload/%' THEN split_part(i.key, '/', 2)
    ELSE split_part(i.key, '/', 1)
END
```

## Excluding Backlog Data

When excluding backlog, the filter should be:
```sql
AND NOT regexp_like(lower(i.key), '(^|/)backload(/|$)')
```

This excludes backlog paths. Note: assigning-authority extraction still handles
`processed/` and `error/` prefixes (see above) because those keys must be
*parsed* correctly before they are excluded by the rule below.

## Excluding `processed/` and `error/` (REQUIRED — global, like the date rule)

Per the November 2026 business rule, `processed/` and `error/` objects are
historical FHIR-processing workflow copies and must be excluded from ALL
analysis — they are duplicate physical objects, not additional submissions. Add
this filter everywhere the inventory is read, next to the date rule:

```sql
-- GLOBAL RULE: exclude processed/ and error/ workflow-prefix objects
AND NOT regexp_like(lower(i.key), '^(processed|error)/')
```

Match only the FIRST path segment so a normal key that merely contains the word
"error" deeper in its path is not dropped. See rules.md for the full rule and its
cross-month caveat.

## Classifying Path Types (for detail queries)

When showing the path type as a column:
```sql
CASE
    WHEN lower(split_part(i.key, '/', 1)) = 'processed' THEN 'PROCESSED'
    WHEN lower(split_part(i.key, '/', 1)) = 'error'     THEN 'ERROR'
    WHEN regexp_like(lower(i.key), '(^|/)backload(/|$)') THEN 'BACKLOG'
    ELSE 'NORMAL'
END AS path_type
```

## Standard Config Block

All queries should use a configurable lookback with inventory lag protection:
```sql
WITH config AS (
    SELECT
        20 AS lookback_days,                -- << CHANGE THIS
        3  AS inventory_lag_days,           -- skip last 3 days for inventory freshness
        2  AS inventory_snapshot_offset_days
),
```

## Data Start Date — March 11, 2026 (REQUIRED)

Data before **March 11, 2026** is not valid for clinical analysis and must be
excluded from EVERY query. Always filter on the submission timestamp:

```sql
-- PDR data contributed before 2026-03-11 contained only the HEADER information,
-- NOT the clinical document. Exclude it from all analysis.
AND i.last_modified_date >= timestamp '2026-03-11 00:00:00'
```

Why: prior to March 11, 2026, sources were submitting only the header/metadata
portion of documents to the PDR — not the actual clinical content (the CCD/TRN
body). Counting those pre-March-11 records would overstate real clinical volume,
so they are excluded everywhere.

This applies to all queries that read `pdr_inventory_prod_data_all`, whether
they use a rolling window, a single snapshot, or an all-time count. Even when
pinned to one snapshot partition, the snapshot still contains documents dated
before March 11 that must be filtered out.

## Cost Estimation

- Approximately 10 GB of data scanned per day of lookback
- Athena charges $5 per TB scanned
- Always include a cost estimate comment at the top of each query
