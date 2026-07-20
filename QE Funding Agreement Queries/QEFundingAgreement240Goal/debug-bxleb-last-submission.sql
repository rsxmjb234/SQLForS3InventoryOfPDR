/*
Debug: Verify last submission timestamp for BXLEB on 2026-05-27.

Expected result from the outage query:
- gap_type:  LAST_SUBMISSION_TO_DAY_END
- gap_start: ~2026-05-27 01:27 AM
- gap_end:   2026-05-28 00:00:00
- Meaning:   no CCD/TRN/ORU data was received from BXLEB after ~1:27 AM yesterday.

This query returns every raw submission event for BXLEB on that day,
ordered latest-first, so you can confirm the cutoff timestamp with your own eyes.
The top row = the last thing received. Nothing after it should exist.
*/

SELECT
    last_modified_date,
    CASE
        WHEN regexp_like(lower(key), '(^|/)ccd(/|$)') THEN 'CCD'
        WHEN regexp_like(lower(key), '(^|/)trn(/|$)') THEN 'TRN'
        WHEN regexp_like(lower(key), '(^|/)oru(/|$)') THEN 'ORU'
    END AS doc_type,
    key
FROM pdr_inventory.pdr_inventory_prod_data_all
WHERE
    dt         = '2026-05-27-01-00'         -- yesterday's inventory partition
    AND last_modified_date >= with_timezone(TIMESTAMP '2026-05-27 00:00:00', 'America/New_York')
    AND last_modified_date <  with_timezone(TIMESTAMP '2026-05-28 00:00:00', 'America/New_York')
    AND bucket             = 'nyec-pdr-prod-bronx'
    AND is_latest          = true
    AND coalesce(is_delete_marker, false) = false
    AND (
        regexp_like(lower(key), '(^|/)ccd(/|$)')
        OR regexp_like(lower(key), '(^|/)trn(/|$)')
        OR regexp_like(lower(key), '(^|/)oru(/|$)')
    )
ORDER BY last_modified_date DESC;
