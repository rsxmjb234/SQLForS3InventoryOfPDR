/*
Expected cost/run: ~$1-2 (single snapshot partition, metadata columns only)
Expected runtime: ~1-2 minutes

QUERY 3 of 3 — Side-by-side: snapshot row count vs unique documents

Goal:
- In one result, show the gap between:
    (a) how many rows exist in a single snapshot partition, and
    (b) how many UNIQUE documents (by bucket+key) that actually represents.
- Also show the total across ALL snapshot partitions (the "billions" number)
  so leadership can see exactly where the big number comes from.

This is the definitive answer to "why are there billions of inventory records?"
- The table stores one row per document PER daily snapshot.
- Multiply unique documents by the number of retained snapshots and you get
  the huge total. It is not a data problem — it is how S3 Inventory snapshots
  accumulate over time.
*/

-- Total rows across ALL snapshot partitions (this is the "billions" figure)
SELECT
    'ALL snapshots combined (raw table count)' AS measure,
    count(*) AS row_count
FROM pdr_inventory.pdr_inventory_prod_data_all
WHERE bucket LIKE 'nyec-pdr-prod-%'

UNION ALL

-- Rows in ONE recent snapshot partition
SELECT
    'One snapshot partition' AS measure,
    count(*) AS row_count
FROM pdr_inventory.pdr_inventory_prod_data_all
WHERE bucket LIKE 'nyec-pdr-prod-%'
  AND is_latest = true
  AND coalesce(is_delete_marker, false) = false
  AND dt = date_format(date_add('day', -1, current_date), '%Y-%m-%d-01-00')

UNION ALL

-- Unique documents (bucket + key) in that one snapshot partition
SELECT
    'Unique documents in one snapshot' AS measure,
    count(DISTINCT bucket || '/' || key) AS row_count
FROM pdr_inventory.pdr_inventory_prod_data_all
WHERE bucket LIKE 'nyec-pdr-prod-%'
  AND is_latest = true
  AND coalesce(is_delete_marker, false) = false
  AND dt = date_format(date_add('day', -1, current_date), '%Y-%m-%d-01-00')

ORDER BY row_count DESC;
