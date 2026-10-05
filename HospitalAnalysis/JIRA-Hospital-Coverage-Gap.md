# JIRA Ticket: Identify Hospitals in NYeC Salesforce Missing from PDR

**Type:** Task / Investigation
**Component:** PDR Data Quality / Hospital Coverage
**Priority:** High
**Reporter:** (you)
**Labels:** pdr, hospital-coverage, data-quality, funding

---

## Summary

Determine, by QE, how many regulated hospital sources that exist in NYeC
Salesforce are **not** submitting data to the PDR. Produce an authoritative,
per-hospital disposition so we can account for every single hospital.

## Background

NYeC Salesforce (sourced from the SCPAs) holds the authoritative list of all
regulated organizations and their Assigning Authorities (AAs). This data is used
for funding and is trusted as the source of truth. By comparing it against what
is actually landing in the PDR, we can find hospitals that appear to be missing.

Important caveat: some hospitals will look "missing" only because the AA they
submit under in the PDR is not their canonical AA (e.g., they submit under an
OID or an alternate code). These are false negatives in the raw comparison and
must be resolved to a real disposition — we must be certain of the status of
every hospital, not just produce a count.

## Methodology

1. **Export from NYeC Salesforce** — the AA Code Report containing all regulated
   organizations and their AAs. This is trusted funding-grade data.
   - Source file: `AA Code Report_09.25.2026UTF-8.csv`
   - Loaded to Athena via `SQLcreateTable.sql` as
     `pdr_inventory.lookup_hospital_assigning_authorities`.
   - Hospital definition:
     - `record_type = 'Assigning Authority'`
     - `organization_type = 'Article 28 - Hospital'`
     - `code` = the AA, `qe_name` = the QE.

2. **Write SQL to COUNT() PDR activity for those sources** — join the Salesforce
   hospital list (LEFT) to PDR inventory so every hospital appears, including
   those with zero data.
   - Query: `reportonhospitals.sql` (counts CCDs/TRNs per hospital, last 10 days,
     excludes backlog, applies the 2026-03-11 clinical-data floor).
   - A hospital with `total_docs = 0` is a candidate "missing from PDR."

3. **Summarize the gap by QE** — count, per QE, how many hospitals have zero
   (or near-zero) PDR submissions.

4. **Resolve false negatives** — for each candidate-missing hospital, confirm
   whether it is truly absent or is submitting under a non-canonical AA (OID or
   alternate code). Work with the QEs to confirm the real submission identity.

## Acceptance Criteria

- [ ] A per-QE count of hospitals present in Salesforce but missing from the PDR.
- [ ] Every candidate-missing hospital is investigated for alternate-AA / OID
      submission before being declared truly missing.
- [ ] The hospital analysis workbook (.XLSX) is updated with a **status on every
      hospital** (e.g., Submitting / Submitting under alternate AA / Truly missing /
      Under investigation), including the QE each is being worked with.
- [ ] No hospital is left without a disposition.

## End in Mind

Update the hospital analysis `.XLSX` with a status for every hospital, driven by
collaboration with each QE, so NYeC has a complete, defensible accounting of
every regulated hospital's PDR submission status.

## Related Artifacts

- `HospitalAnalysis/AA Code Report_09.25.2026UTF-8.csv` — Salesforce export (source of truth)
- `HospitalAnalysis/SQLcreateTable.sql` — Athena table DDL for the Salesforce export
- `HospitalAnalysis/reportonhospitals.sql` — per-hospital CCD/TRN count query
- `HospitalAnalysis/Updatedoct5thAllHospitalsContributingTRNnotCCD.csv` — supporting analysis (hospitals sending TRN but not CCD)
