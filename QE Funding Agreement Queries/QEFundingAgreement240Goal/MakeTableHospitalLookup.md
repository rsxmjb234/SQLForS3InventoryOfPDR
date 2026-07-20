CREATE EXTERNAL TABLE pdr_inventory.hospital_aa_reference (
    organization_type   STRING,
    assigning_authority STRING,
    secondary_aa        STRING,
    qe_name             STRING
)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES (
    'separatorChar' = ',',
    'quoteChar'     = '"'
)
LOCATION 's3://pdr-nyec-local/hospitalAATable/'
TBLPROPERTIES (
    'skip.header.line.count' = '1',
    'classification'         = 'csv'
);
