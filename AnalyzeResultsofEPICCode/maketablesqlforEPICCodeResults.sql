CREATE EXTERNAL TABLE IF NOT EXISTS pdr_inventory.ehr_software_analysis (
    path                    STRING,
    filename                STRING,
    processing_time_ms      INT,
    file_size_bytes         INT,
    assigning_authority     STRING,
    oid                     STRING,
    software_name           STRING,
    manufacturer_model_name STRING,
    custodian_org_name      STRING,
    template_ids            STRING,
    has_epic_oid            STRING,
    epic_oids_found         STRING,
    all_oid_families        STRING,
    indent_style            STRING,
    ehr_guess               STRING,
    ehr_guess_reason        STRING,
    parse_type              STRING
)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES (
    'separatorChar' = ',',
    'quoteChar'     = '"'
)
STORED AS TEXTFILE
LOCATION 's3://pdr-nyec-local/EPICHospitalAnalysis/'
TBLPROPERTIES (
    'skip.header.line.count' = '1'
)
