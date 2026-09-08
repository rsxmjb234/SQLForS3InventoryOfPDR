/*
Make table for Verato AA lookup.
- Data lives in S3: s3://pdr-nyec-local/Lookup-VeratoAA/
- All fields are strings.
- Fields: QE, ASSIGNING_AUTHORITY, SMRN_COUNT, fixed_code, qe_aa_together
*/

CREATE EXTERNAL TABLE pdr_inventory.lookup_verato_aa (
  qe string,
  assigning_authority string,
  AAAsViewedByQE string,
  QEAndAAAppended string
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
