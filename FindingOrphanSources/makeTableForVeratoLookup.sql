/*
Make table for Verato AA lookup (the MPI extract from Tom).
- Data lives in S3: s3://pdr-nyec-local/Lookup-VeratoAA/  (keep exactly ONE file there)
- All fields are strings (OpenCSVSerde). Cast in queries when you need a number,
  e.g. TRY_CAST(member_count_native_id AS bigint).
- File columns -> table columns (same order):
    QE                      -> qe
    AA                      -> assigning_authority
    AAS_VIEWED_BY_QE        -> aaasviewedbyqe     (AA as the QE sees it: Bronx underscores
                                                    become spaces, .DUPLICATE* suffixes dropped)
    QE_AND_AA_APPENDED      -> qeandaaappended    (QE|AAS_VIEWED_BY_QE)
    MEMBER_COUNT_NATIVE_ID  -> member_count_native_id  (added Nov 2026: Verato member count
                                                    per native ID)

The live table was updated in place (Nov 17, 2026) with:
  ALTER TABLE pdr_inventory.lookup_verato_aa
    ADD COLUMNS (member_count_native_id string);
Use the CREATE below only to rebuild the table from scratch.
*/

CREATE EXTERNAL TABLE pdr_inventory.lookup_verato_aa (
  qe string,
  assigning_authority string,
  AAAsViewedByQE string,
  QEAndAAAppended string,
  member_count_native_id string
)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES (
  'separatorChar' = ',',
  'quoteChar' = '"',
  'escapeChar' = '\\'
)
STORED AS TEXTFILE
LOCATION 's3://pdr-nyec-local/Lookup-VeratoAA/'
TBLPROPERTIES (
  'skip.header.line.count'='1',
  'use.null.for.invalid.data'='true'
);
