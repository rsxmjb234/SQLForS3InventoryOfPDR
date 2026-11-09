/*
Make-table query for the ADT message counts (monthly, per hospital).

SOURCE FILE
- s3://pdr-nyec-local/LookupADTData/EG ADT Counts 20261106 for Michael.csv
  (local copy: ADTCounts\EG ADT Counts 20261106 for Michael.csv)
- 3 months of data: 2026-08, 2026-09, 2026-10. 241 rows per month, 723 rows total.
  Total 31,580,306 ADT messages across the 3 months.
- One row = one hospital (NYS facility ID) under one assigning authority (AA),
  reported through one originating QE, for one month.

HOW TO USE
- Run this once in Athena. The table name is written as pdr_inventory.lookup_adt_counts,
  so it goes into the pdr_inventory database (same as
  lookup_hospital_assigning_authorities) whatever the Database dropdown says.
  The table reads EVERY file in the
  LookupADTData/ folder, so to add more months drop another file with the same
  6 columns in that folder (and make sure months do not overlap an older file).
- All columns come in as text (OpenCSVSerde). Cast message_count to bigint and
  message_month to date when you use them - see the examples at the bottom.

COLUMNS
- message_month            first day of the month, e.g. 2026-08-01
- originating_qe           BRONX, GRRHIO (Rochester), HEALTHIX, HECDCS
                           (HealtheConnections), HIXNY, TXD (techbd)
- nys_permanent_facility_id  joins to nys_facility_id in
                           lookup_hospital_assigning_authorities
- facility_name
- assigning_authority      the AA the ADT came in under
- message_count            number of ADT messages that month

KNOWN QUIRKS IN THIS FILE (handle when you use it)
- 6 rows have hospital names with commas inside quotes (for example
  "Brooks-TLC Hospital System, Inc."). The quote settings below handle them.
- Some rows repeat exactly except for the spelling of facility_name (for example
  "Medina Memorial Hospital" vs "MEDINA MEMORIAL HOSPITAL", Calvary Hospital vs
  Calvary Brooklyn). Same month, QE, facility, AA and count. Count each once:
  group by month + QE + facility + AA and take max(message_count), NOT sum.
- A hospital can report through two QEs with DIFFERENT counts (Wyoming County
  Community Hospital via GRRHIO and TXD). Those are separate real rows.
- The file has a UTF-8 byte-order mark on line 1. It sits in the header line,
  which is skipped, so it does not affect the data.
*/

DROP TABLE IF EXISTS pdr_inventory.lookup_adt_counts;

CREATE EXTERNAL TABLE pdr_inventory.lookup_adt_counts (
  message_month string,
  originating_qe string,
  nys_permanent_facility_id string,
  facility_name string,
  assigning_authority string,
  message_count string
)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES (
  'separatorChar' = ',',
  'quoteChar' = '"',
  'escapeChar' = '\\'
)
STORED AS TEXTFILE
LOCATION 's3://pdr-nyec-local/LookupADTData/'
TBLPROPERTIES ('skip.header.line.count' = '1');

/*
-- SANITY CHECK (run after creating the table). Expect 3 months x 241 rows each,
-- 31,580,306 messages in total, and 6 QEs.
SELECT
    message_month,
    count(*) AS row_count,
    count(DISTINCT nys_permanent_facility_id) AS facilities,
    sum(CAST(message_count AS bigint)) AS adt_messages
FROM pdr_inventory.lookup_adt_counts
GROUP BY message_month
ORDER BY message_month;

-- EXAMPLE: ADT per hospital per month, repeats collapsed, ready to join to the
-- hospital roster on facility ID.
SELECT
    CAST(message_month AS date) AS message_month,
    originating_qe,
    nys_permanent_facility_id,
    upper(trim(assigning_authority)) AS aa,
    max(CAST(message_count AS bigint)) AS adt_messages
FROM pdr_inventory.lookup_adt_counts
GROUP BY 1, 2, 3, 4;
*/
