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

This correctly excludes ONLY backlog while keeping processed/, error/, and normal paths.
Documents in `processed/` and `error/` paths are real-time submissions (not backlog).

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

## Cost Estimation

- Approximately 10 GB of data scanned per day of lookback
- Athena charges $5 per TB scanned
- Always include a cost estimate comment at the top of each query
