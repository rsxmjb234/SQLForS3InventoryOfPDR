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
- If the first path segment is one of `processed`, `error`, or `backload`, use path segment 2
- Otherwise, use path segment 1

### Data Type (Required)
Required data types for outage compliance are:
- CCD
- TRN
- ORU

A record is considered one of these data types when the key path contains that token as a path segment.

### Data Type — Labs
Lab results are identified by the **`lab`** path segment in the S3 key, e.g.:
`BXLEB/lab/2026/Oct/09/20/bronx_BXLEB_....hl7`

Match labs with:
```sql
regexp_like(lower(key), '(^|/)lab(/|$)')
```
Labs are a distinct document type from CCD and TRN. When counting "labs" in
reporting (e.g., the PDR fact sheet), use the `lab` token — NOT `oru`. Earlier
queries guessed labs were under an `oru` segment; the actual segment is `lab`.

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
- last_modified_date >= 2026-03-11 00:00:00 (see Clinical Data Start Date below)
- bucket matches nyec-pdr-prod-%
- is_latest = true
- is_delete_marker is false (or null treated as false)
- key path indicates required data type (CCD, TRN, or ORU)

## Clinical Data Start Date (REQUIRED — March 11, 2026)
Documents contributed to the PDR before **2026-03-11** must NOT be counted in any
analysis. Prior to that date, sources were submitting only the HEADER / metadata
portion of documents, not the actual clinical document (the CCD/TRN body).
Including those records overstates real clinical volume.

Apply this filter on the submission event time in EVERY query that reads the
inventory, in addition to any dt/partition or window filters:

```sql
-- PDR data contributed before 2026-03-11 was only the HEADER information, not the clinical document; exclude it.
AND last_modified_date >= timestamp '2026-03-11 00:00:00'
```

## Submission Date — parse from the KEY, not last_modified_date (REQUIRED for volume)
`last_modified_date` is NOT a reliable submission date. S3 updates it whenever an
object's metadata changes or it is bulk-rewritten, and PDR does this routinely.
Bulk re-stamp events (e.g. 2026-09-14, -15, -22) moved millions of OLD documents
to a later last_modified_date, which falsely inflated monthly volume and hid real
trends.

The TRUE submission date is embedded in the S3 key path, which never changes once
the object is written:

```
<assigningAuthority>/<type>/YYYY/Mon/DD/HH/...      e.g.  MMC/trn/2026/Aug/15/12/...
```

For ANY volume / counting / day / month analysis, derive the submission date from
the key (verified to parse for 100% of ~300M documents):

```sql
TRY(date_parse(
    regexp_extract(key, '(?i)(?:ccd|trn|lab|oru)/(\d{4}/[A-Za-z]{3}/\d{2})/', 1),
    '%Y/%b/%d'
)) AS submission_date
```

Then bucket/filter on `submission_date` (a DATE). Apply the clinical-data floor on
it: `AND submission_date >= DATE '2026-03-11'`. You MAY keep
`last_modified_date >= timestamp '2026-03-11 00:00:00'` as a pure scan reducer
(re-stamps only move dates forward, so it never drops a valid row).

Because dating by the key resolves re-stamped docs to their real dates, NO
anomaly-day / bulk-spike-day exclusion list is needed. (The former 2026-09-14 /
-15 / -22 exclusion rule is retired.)

Exception: SystemWide-DailyTotals-FindSpikeDays.sql intentionally still counts by
last_modified_date, because its purpose is to DETECT re-stamp artifact days.

Note: the 240-minute gap query is a separate case — the key path only has
hour-level granularity, so gap detection still uses last_modified_date timestamps.

Note: outage/gap (240-minute) detection is NOT affected by this rule — a bulk of
submissions on one day does not create gaps — so it is applied to volume queries,
not required for the 240-minute query.

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
