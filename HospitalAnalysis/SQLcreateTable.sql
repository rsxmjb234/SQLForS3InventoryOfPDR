/*
Make table for the Hospital Assigning Authority list (Salesforce / SFDC export).

Source: SFDCExort09-29-2028ListOFHospitals.txt
Data lives in S3: s3://pdr-nyec-local/Lookup-Hospital assigning Authorities/
Format: CSV (OpenCSVSerde), quoted fields, header row skipped.

Columns (in file order):
  nys_facility_id          NYS / Facility ID (e.g. 1164)
  shin_ny_id               SHIN-NY ID (e.g. FS0000001164)
  organization_status      e.g. Active
  qe_participation_status  e.g. Active
  participating            e.g. 1
  organization_type        e.g. "Article 28 - Hospital"
  organization_description e.g. Hospital
  organization_name        e.g. "BronxCare Hospital Center"
  qe_name                  the QE (e.g. "Bronx RHIO")
  record_type              e.g. "Assigning Authority"
  code                     the AA code (e.g. BXLEB, MMC, SBH)
  code_status              e.g. Active
  code_deactivation_date   deactivation date (may be blank)
  code_level               code level (may be blank)
  code_level_description   code level description (may be blank)
  oid_feed_type            OID feed type (may be blank)
  code_notes               notes (may be blank)

ENCODING / EXPORT — IMPORTANT:
  The original export was UTF-16 (Excel "Unicode Text"), which Athena cannot
  read as CSV. It produced mangled rows, blank lines between records, and a
  stray trailing quote on each line.

  RE-EXPORT the file as "CSV UTF-8 (Comma delimited) (*.csv)" in Excel
  (NOT "Unicode Text" and NOT "Unicode CSV"). That produces:
    - UTF-8 encoding (no spaced-out characters)
    - plain comma separators
    - normal line endings (no blank rows)
    - no whole-line quoting
  Then upload the UTF-8 file to the S3 prefix below.

To apply:
  1. (If re-creating) DROP TABLE pdr_inventory.lookup_hospital_assigning_authorities;
  2. Run the CREATE below.
*/

CREATE EXTERNAL TABLE `pdr_inventory.lookup_hospital_assigning_authorities`(
  `nys_facility_id` string,
  `shin_ny_id` string,
  `organization_status` string,
  `qe_participation_status` string,
  `participating` string,
  `organization_type` string,
  `organization_description` string,
  `organization_name` string,
  `qe_name` string,
  `record_type` string,
  `code` string,
  `code_status` string,
  `code_deactivation_date` string,
  `code_level` string,
  `code_level_description` string,
  `oid_feed_type` string,
  `code_notes` string)
ROW FORMAT SERDE
  'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES (
  'separatorChar' = ',',
  'quoteChar'     = '\"',
  'escapeChar'    = '\\')
STORED AS TEXTFILE
LOCATION
  's3://pdr-nyec-local/Lookup-Hospital assigning Authorities/'
TBLPROPERTIES (
  'classification'='csv',
  'skip.header.line.count'='1'
);
