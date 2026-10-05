# JIRA Ticket: Identify Hospital Assigning Authorities in NYeC Salesforce Missing from PDR

**Type:** Task / Investigation
**Component:** PDR Data Quality / Hospital Coverage
**Priority:** High
**Reporter:** (you)
**Labels:** pdr, hospital-coverage, data-quality, funding

---

## Summary

Determine how many regulated hospital assigning authorities (AAs) that exist in
NYeC Salesforce are **not** submitting data to the PDR. Work at the assigning
authority (code) level only — QE is not part of this analysis. Produce an
authoritative, per-AA disposition so we can account for every single hospital.

## Background

NYeC Salesforce (sourced from the SCPAs) holds the authoritative list of all
regulated organizations and their Assigning Authorities (AAs). This data is used
for funding and is trusted as the source of truth. By comparing the hospital AA
codes against what is actually landing in the PDR, we can find hospital AAs that
appear to be missing.

Important caveat: some hospital AAs will look "missing" only because the code
they submit under in the PDR is not their canonical AA (e.g., they submit under
an OID or an alternate code). These are false negatives in the raw comparison
and must be resolved to a real disposition — we must be certain of the status of
every hospital AA, not just produce a count.

## Methodology

1. **Export from NYeC Salesforce** — the AA Code Report containing all regulated
   organizations and their AAs. This is trusted funding-grade data.
   - Source file: `AA Code Report_09.25.2026UTF-8.csv`
   - Loaded to Athena via `SQLcreateTable.sql` as
     `pdr_inventory.lookup_hospital_assigning_authorities`.
   - Hospital definition:
     - `record_type = 'Assigning Authority'`
     - `organization_type = 'Article 28 - Hospital'`
     - `code` = the AA (QE is intentionally ignored).

2. **Write SQL to COUNT() PDR activity for those AAs** — join the Salesforce
   hospital AA list (LEFT) to PDR inventory, matching on the AA code only, so
   every hospital AA appears, including those with zero data.
   - Query: `reportonhospitals.sql` (counts CCDs/TRNs per AA, last 10 days,
     excludes backlog, applies the 2026-03-11 clinical-data floor).
   - A hospital AA with `total_docs = 0` is a candidate "missing from PDR."

3. **Resolve false negatives** — for each candidate-missing AA, confirm whether
   it is truly absent or is submitting under a non-canonical AA (OID or alternate
   code). Work to confirm the real submission identity for each.

## Acceptance Criteria

- [ ] A count of hospital assigning authorities present in Salesforce but missing
      from the PDR.
- [ ] Every candidate-missing AA is investigated for alternate-AA / OID
      submission before being declared truly missing.
- [ ] The hospital analysis workbook (.XLSX) is updated with a **status on every
      hospital assigning authority** (e.g., Submitting / Submitting under alternate
      AA / Truly missing / Under investigation).
- [ ] No hospital AA is left without a disposition.

## End in Mind

Update the hospital analysis `.XLSX` with a status for every hospital assigning
authority, so NYeC has a complete, defensible accounting of every regulated
hospital AA's PDR submission status.

## Related Artifacts

- `HospitalAnalysis/AA Code Report_09.25.2026UTF-8.csv` — Salesforce export (source of truth)
- `HospitalAnalysis/SQLcreateTable.sql` — Athena table DDL for the Salesforce export
- `HospitalAnalysis/reportonhospitals.sql` — per-AA CCD/TRN count query
- `HospitalAnalysis/Updatedoct5thAllHospitalsContributingTRNnotCCD.csv` — supporting analysis (hospitals sending TRN but not CCD)
