DROP TABLE IF EXISTS lookup_hospital_assigning_authorities;

CREATE EXTERNAL TABLE lookup_hospital_assigning_authorities (
  nys_facility_id string,
  shin_ny_id string,
  organization_status string,
  qe_participation_status string,
  participating string,
  organization_type string,
  organization_description string,
  organization_name string,
  qe_name string,
  record_type string,
  code string,
  code_status string,
  code_deactivation_date string,
  code_level string,
  code_level_description string,
  oid_feed_type string,
  code_notes string,
  scaler_size string
)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES (
  'separatorChar' = ',',
  'quoteChar' = '"',
  'escapeChar' = '\\'
)
STORED AS TEXTFILE
LOCATION 's3://pdr-nyec-local/Lookup-Hospital assigning Authorities/'
TBLPROPERTIES ('skip.header.line.count' = '1');
