CREATE EXTERNAL TABLE pdr_inventory.lookup_stdev_average_for_hospitals (
  assigning_authority string,
  qe string,
  day_type string,
  metric string,
  mean_value bigint,
  stdev_value bigint,
  sample_days int,
  baseline_start_epoch_day bigint,
  baseline_end_epoch_day bigint,
  lower_2stdev bigint,
  upper_2stdev bigint
)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES (
  'separatorChar' = ',',
  'quoteChar' = '"',
  'escapeChar' = '\\'
)
STORED AS TEXTFILE
LOCATION 's3://pdr-nyec-local/Lookup-STDEVandAverageForHospitals/'
TBLPROPERTIES (
  'skip.header.line.count'='1',
  'use.null.for.invalid.data'='true'
);