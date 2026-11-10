# Hospital volume vs SPARCS size, QE by QE (November 2026)

Source: 2-SQL/HospitalSystemsByQE-SparcsVsVolume.sql, results in
3-Results/results-HospitalSystemsByQE-SparcsVsVolume.csv (275 rows, 194 SPARCS hospitals).
Volume is 28 complete days from one inventory snapshot, annualized (count / 28 * 365).
ADT comes from the EG ADT counts file (Aug-Oct 2026, 92 days, annualized).
Directionally accurate, not exact.

## Overall

- 117 of 194 hospitals (60%) send CCD.
  - Large (SPARCS 8-10): 28 of 60
  - Medium (4-7): 48 of 78
  - Small (1-3): 41 of 56
- 32 Large hospitals send no CCD: 26 Healthix, 4 Rochester, 2 Bronx.
- Annual volume (AA level): CCD 55.9M, TRN 98.8M, LAB 146.0M, ADT 118.0M.
- Sniff tests (system level, fail = 20+ places worse on volume than on SPARCS size),
  Part 2 (-2) feeds skipped:
  - CCD: 75 pass, 14 fail
  - ADT: 114 pass, 41 fail
  - ORU/LAB: 82 pass, 10 fail

## Bronx

- 0 of its 3 own hospitals send CCD.
- Montefiore (MMC, 4 hospitals) sends 4.3M CCD a year, but that AA is shared with
  Healthix.
- Sniff fails: ADT 1.

## HEALTHeLINK

- 18 of 21 hospitals send CCD, through 7 of its 11 AAs (4.8M a year).
- Sniff fails: ADT 1, ORU 1.

## HealtheConnections

- 54 of 55 hospitals send CCD (29.6M a year, the largest QE). St. Joseph's Medical
  Center is the one that sends none.
- Volume only shows up once Salesforce's old numeric codes are mapped to HEC's
  current names (they stopped about March 30). The SFDC fix job does this.
- The -2 codes are Part 2 (substance-use) feeds with small volume by design. They are
  now left out of the sniff tests; they caused 6 of HEC's 9 earlier ADT fails.
- Sniff fails: CCD 5, ADT 3, ORU 1.

## Hixny

- 23 of 23 hospitals send CCD under their DOC AA (3.6M a year). None send CCD under
  the base AA; TRN, LAB and ADT go on the base AA.
- Sniff fails: CCD 5, ADT 6, ORU 4.

## Rochester

- 0 hospitals send CCD on their own AA.
- 4 get CCD into PDR through HEC: Auburn, Canton-Potsdam, Gouverneur, Massena.
- Sniff fails: ORU 1.

## Healthix

- 18 of 75 hospitals send CCD (24%, 13.7M a year). This is the biggest gap: most of
  the Large hospitals with no CCD are Healthix.
- Sniff fails: CCD 4, ADT 30, ORU 3.

## Caveats

- ECMC counts as sending CCD only because the ADT file puts it on KHSEPI. Needs
  confirming.
- 37 Salesforce hospitals have no SPARCS size. They are not in the report and are
  not judged.
- Where two hospitals on one AA tie on size, the chain_name guess can flip between
  them (cosmetic, e.g. St. John's Riverside).
- The sniff counts with Part 2 skipped were recomputed from the latest results file
  using the same rules as the SQL (the recompute matched the SQL's earlier results on
  all 347 tests). The next report run will show them directly.
