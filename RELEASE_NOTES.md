# Release Notes

## v1.1.0 — 2026-09-24

### Highlights

This release standardizes the analysis window and hardens the query library
around two important data-quality findings.

### Added

- **March 11, 2026 data floor across all queries.** Every query that reads
  `pdr_inventory.pdr_inventory_prod_data_all` now filters
  `last_modified_date >= '2026-03-11'`. PDR data contributed before that date
  contained only the **header** information, not the clinical document body, so
  including it would overstate real clinical volume. Each query carries an
  inline comment explaining the exclusion.
- **`ad-hock/countBYQEalltime.sql`** — total document population by QE
  (CCD / TRN / ORU / backlog), pinned to a single inventory snapshot.
- **`DiagnoseReportOfBillionsOfInventory/`** — a three-query diagnostic and a
  CIO-ready memo (`Explore1BHypothisys.md`) explaining why a naive table count
  returns ~59.8 billion rows while the true document population is ~531 million
  (S3 Inventory snapshot accumulation, ~112 retained snapshots, zero
  intra-snapshot duplication).
- **`FindingOrphanSources/`** — queries and reports identifying assigning
  authorities that contribute to the PDR but are not present in the Verato MPI,
  including MPI-status labeling and most-recent-submission dates.
- **`AnalyzeResultsofEPICCode/`** — coverage query for sources contributing
  CCDs that are not yet classified in the EHR software analysis.
- **`.kiro/steering/sql-patterns.md`** — team steering rules covering:
  - Correct assigning-authority extraction (handles `processed/`, `error/`,
    `backload/` prefixes).
  - Correct backlog exclusion.
  - Path-type classification.
  - The March 11 data floor and its rationale.

### Fixed

- **Assigning-authority parsing defect.** Queries that only handled the
  `backload/` prefix were mis-parsing `processed/` and `error/` paths (reading
  the literal words as the AA). All queries now use the corrected 4-case
  extraction.
- **`hospital_aa_reference` table spec.** Corrected DDL adds the `secondary_aa`
  column so `qe_name` aligns with the source CSV columns.

### Notes

- One intentional exception to the March 11 floor: the first measure in
  `DiagnoseReportOfBillionsOfInventory/3-SideBySideComparison.sql` (the raw
  all-snapshots count) is left unfiltered on purpose, to demonstrate the
  snapshot-inflation effect.
- `.gitignore` keeps result CSVs and workbooks out of the repo, with an
  exception allowing the `FindingOrphanSources/` CSVs to be tracked.

---

## v1.0.0 — Initial release

- SQL query library for analyzing the PDR S3 inventory in Amazon Athena.
- Statistical variance detection, QE funding-agreement volume tracking,
  backlog speed reporting, and various ad-hoc analyses.
