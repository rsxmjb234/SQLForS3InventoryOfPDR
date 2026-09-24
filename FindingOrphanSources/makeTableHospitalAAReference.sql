/*
Make table for the Hospital Assigning Authority reference.

Data lives in S3: s3://pdr-nyec-local/hospitalAATable
Source is a CSV (OpenCSVSerde), header row skipped.

Columns (CONFIRMED — the QE name lives in qe_name, NOT secondary_aa):
  organization_type   e.g. "Article 28 - Hospital"
  assigning_authority the AA code/name used to match S3 inventory paths (e.g. 1153, BELLEVUE)
  secondary_aa        a secondary AA label (e.g. HEALTHELINK, HEALTHIX) — NOT the QE
  qe_name             the QE the hospital belongs to

IMPORTANT:
- Earlier queries referenced qe_name but the table was defined with only 3
  columns, so qe_name resolved incorrectly. This DDL adds secondary_aa so the
  column positions line up with the CSV and qe_name reads correctly.

To apply:
  1. DROP TABLE pdr_inventory.hospital_aa_reference;
  2. Run the CREATE below.
*/

CREATE EXTERNAL TABLE `pdr_inventory.hospital_aa_reference`(
  `organization_type` string COMMENT 'from deserializer',
  `assigning_authority` string COMMENT 'from deserializer',
  `secondary_aa` string COMMENT 'from deserializer',
  `qe_name` string COMMENT 'from deserializer')
ROW FORMAT SERDE
  'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES (
  'quoteChar'='\"',
  'separatorChar'=',')
STORED AS INPUTFORMAT
  'org.apache.hadoop.mapred.TextInputFormat'
OUTPUTFORMAT
  'org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat'
LOCATION
  's3://pdr-nyec-local/hospitalAATable'
TBLPROPERTIES (
  'classification'='csv',
  'skip.header.line.count'='1'
);
