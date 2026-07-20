# PDR Submission Business Rules for QEs

## Purpose
These rules define how PDR data submission compliance is measured for each Qualified Entity (QE).

A compliance outage event occurs when required data is not submitted to the PDR for a continuous 240-minute period.

## Core Definitions

### QE (Qualified Entity)
A QE is identified from the S3 bucket name after removing these prefixes/suffixes:
- Remove prefix: nyec-pdr-prod-
- Remove optional suffix: -part2

Example:
- nyec-pdr-prod-bronx -> bronx
- nyec-pdr-prod-bronx-part2 -> bronx

### Assigning Authority
Assigning Authority is parsed from the S3 key path:
- If key starts with backload/, use path segment 2
- Otherwise, use path segment 1

### Data Type (Required)
Required data types for outage compliance are:
- CCD
- TRN
- ORU

A record is considered one of these data types when the key path contains that token as a path segment.

### Time
- Reporting day is yesterday (a full completed day).
- Day start is yesterday at 00:00:00.
- Day end is today at 00:00:00.
- Gap duration is measured in minutes between valid submission timestamps.

### Submission Event Time
Submission event time is based on last_modified_date.

Important:
- dt is an inventory partition/snapshot field used for scan reduction.
- dt is not the submission event timestamp.
- Compliance calculations must use last_modified_date for time windows.

## Record Inclusion Rules
A record is included only if all are true:
- dt matches yesterday partition value (YYYY-MM-DD-01-00)
- last_modified_date is within yesterday window [day_start, day_end)
- bucket matches nyec-pdr-prod-%
- is_latest = true
- is_delete_marker is false (or null treated as false)
- key path indicates required data type (CCD, TRN, or ORU)

## Outage Detection Rules (240-Minute Rule)
Outages are measured per:
- QE
- Assigning Authority

Three outage patterns are detected:
- Between submissions: time between consecutive submissions is >= 240 minutes
- Day start to first submission: first submission occurs >= 240 minutes after day start
- Last submission to day end: day ends >= 240 minutes after last submission

## Gap Types in Output
- BETWEEN_SUBMISSIONS
- DAY_START_TO_FIRST_SUBMISSION
- LAST_SUBMISSION_TO_DAY_END

## Compliance Interpretation
For each QE and assigning authority, any detected gap of 240 minutes or more is an outage event for that day.

## Operational Expectations for QEs
To remain compliant, each QE should:
- Continuously submit required data types (CCD, TRN, ORU)
- Avoid any 4-hour interruption in submissions
- Monitor both routine and backload path patterns so assigning authority is correctly represented
- Resolve feed interruptions before they reach 240 minutes

## Data Quality Notes
- Unexpected assigning authority values can occur when key path structure changes.
- Path format should remain consistent so assigning authority and data type are correctly classified.
- Optional inventory_source partition filtering should be used in production queries to reduce scan size.
