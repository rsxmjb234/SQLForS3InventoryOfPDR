# Memo: hospital CCDs vs SPARCS, QE by QE (November 2026)

We run month over month, and I have only recently started to look at this vs SPARCS.

Here is what today looks like:
1. Still early days. The data is moving around and will keep moving.
2. We definitely have hospitals that don't send CCDs.
3. SFDC and what we see in the wild still don't line up, but we can now see past it.

This covers the 194 participating hospitals that SPARCS knows, grouped by assigning
authority (AA). The numbers are 28 days of data scaled to a year, so treat them as
directional. ADT is in, from the ADT counts file (Aug-Oct 2026).

Since last time: for HealtheConnections we map the old SFDC codes to their current
AAs. We also pick up the AA each hospital actually uses in the ADT file, look for the
Hixny DOC AA, and check the Bronx and Healthix buckets by PDR bucket. That turned up
system-wide codes and one code shared by two systems.

Percentages are the share of each QE's hospital AAs in SFDC that send CCDs under
those AAs. Part 2 (substance-use) AAs are left out.

## Bronx: 33%

3 hospital AAs in SFDC, and 1 sends CCDs.

Sending CCDs (MMC, Montefiore): about 4.1M CCDs, 8.2M TRN and 10.8M LAB a year.

| Hospital | NYS ID | SPARCS size |
|---|---|---|
| Montefiore Medical Center - Henry & Lucy Moses Div | 1169 | 10 |
| Montefiore Med Center - Jack D Weiler Hosp of A Einstein College Div | 3058 | 9 |
| Montefiore Medical Center - Wakefield Hospital | 1168 | 8 |

Montefiore Westchester Square (1185) is also on MMC. It has no SPARCS size in SFDC,
so it isn't in the 194.

In SFDC, no CCDs in PDR (not in any bucket):

| Hospital | NYS ID | AA | SPARCS size | Sends |
|---|---|---|---|---|
| BronxCare Hospital Center | 1178 | BXLEB | 9 (Large) | TRN, LAB, ADT |
| BronxCare Hospital Center | 1164 | BXLEB | 4 (Medium) | TRN, LAB, ADT |
| SBH Health System | 1176 | SBH | 8 (Large) | TRN, LAB, ADT |

- Lisa talked to them and confirmed they don't get CCDs from either.
- Watch out: SFDC uses MMC for two different systems, Montefiore under Bronx and
  Maimonides under Healthix. Only the PDR bucket tells them apart. The ADT file
  splits them correctly.
- ADT: about 9.3M a year across the three.

## HEALTHeLINK: 67%

- 9 hospital AAs, and 6 send CCDs: CHSEPI, KHSEPI, UPMCEP, RPCI, BRTRND and NFMMC.
  About 4.7M CCDs a year.
- ECMC, UMMC and MEDINA send no CCDs.
- ECMC's CCDs may be coming in under KHSEPI, which is where the ADT file puts ECMC.
  Needs confirming.
- Wyoming County (WCCHS) is also listed under Rochester. It sends CCDs, so counting
  it makes 7 of 10.
- ADT: everyone but UMMC sends it, about 18.6M a year.

## HealtheConnections: 95% (was 0%)

- The hunch was right. When they moved to HECDSS they got all new AAs, and those are
  not in SFDC. Once the old SFDC codes are mapped to the new ones, 38 of 40 AAs send
  CCDs: 54 of 55 hospitals, about 29.6M CCDs a year. That is the largest of any QE.
- Only St. Joseph's Medical Center sends none. Its AAs send ADT only.
- 5 AAs in active use are not in HEC's own lookup and only show up in the ADT file:
  CROUSE, UHS, ST-LUKES-CORN, WEST-MIDHUDSON-3 and HAHV-KINGSTON-3. Between them
  they send about 5M CCDs a year.
- The -2 codes are Part 2 feeds. They are small by design and not counted.
- ADT: about 20.9M a year.
- SFDC itself still has the old codes. We fix them on the way in; SFDC should be
  updated at the source.

## Hixny: 4% or 100%, depending how you count

A very mixed story.

- Why 4%: Hixny has 26 AAs on file in SFDC, and only one shows any CCDs. That one is
  MMGKIDSK, a tiny Massena feed.
- Why 100%: they told us they code CCDs to DOC sources (MIBDOC, AMHSAMCHDOC, PAPLDOC
  and similar) that aren't in SFDC. With the DOC suffix, every Hixny hospital sends
  CCDs: 26 DOC AAs, about 3.6M a year. HealthAlliance and Margaretville send theirs
  through HealtheConnections.
- The pin from last time is real. ADT and TRN come in on the base AA (MIB) and CCDs
  on the DOC AA (MIBDOC), so one hospital has two AAs. Bassett goes further: its ADTs
  arrive under BAS* codes (BASMIBO, BASAOFO, BASCRHO, BASLFHO, BASOCO) that aren't in
  SFDC either.
- ADT: about 5.2M a year. Several SFDC codes (WMC, RRHCPH, RRHGH, RRHMH, WMCBSMGGSH)
  send TRN but no ADT, so their ADT must be arriving on another code.

## Rochester: 0%

- 6 hospital AAs, and none send CCDs.
- This one is not a code mismatch. RGHS (10 hospitals) and URMC (6 hospitals) send
  plenty of ADT and TRN, just no CCDs. URMC's ADT comes in under URMCEPIC, which isn't
  in SFDC.
- ADT: about 22.0M a year, URMCEPIC 15.2M and RGHS 5.2M.
- ACH and CPH send almost nothing, because Auburn and Canton-Potsdam send under
  HealtheConnections (and Hixny DOC) codes instead. Counting those, 7 of the 23
  hospitals SFDC lists under Rochester get CCDs into PDR, and all but one come through
  another QE.

## Healthix: 23% or 64%, depending how you count

This is the most interesting one.

- Why 23%: 75 hospital AAs in SFDC, and 17 send CCDs under their own code. About
  13.9M a year. Mount Sinai (MSMC) alone is 6.9M. Maimonides (MMC) sends only 0.2M;
  the Bronx MMC volume belongs to Montefiore.
- Why 64%: four systems send CCDs under one system-wide code that isn't in SFDC.
  It's the HECDSS story again. Counting them, 48 of 75 AAs:

| System code | System | Hospital AAs it covers | CCD/yr |
|---|---|---|---|
| NYUMC | NYU Langone | 5 | 25.2M (plus 12.5M TRN, 27.4M LAB) |
| NYPRES | NewYork-Presbyterian | 9 | 17.4M |
| NYCHH | NYC Health + Hospitals | 11 | 7.1M |
| CHSLI | Catholic Health LI | 6 | 1.4M |

- These are system codes, so we can't tie the CCDs to a specific hospital. Some of
  the volume is likely from their practices rather than the hospitals.

### Truly no CCD under any code

Northwell: 15 AAs. The only Northwell-looking code in PDR is NWPE, at about 107K
CCDs a year.

| Hospital | NYS ID | AA | Size |
|---|---|---|---|
| Long Island Jewish Medical Center | 1630 | LIJMC | Large |
| North Shore University Hospital | 541 | NHSUH | Large |
| Lenox Hill Hospital | 1450 | LHH | Large |
| Staten Island University Hosp-North | 1740 | SIUHN | Large |
| South Shore University Hospital | 924 | SSH | Large |
| Long Island Jewish Forest Hills | 1638 | LIJFH | Large |
| Huntington Hospital | 913 | HUNT | Large |
| Long Island Jewish Valley Stream | 518 | LIJVS | Medium |
| Glen Cove Hospital | 490 | GC | Medium |
| Plainview Hospital | 552 | PLVH | Medium |
| Syosset Hospital | 550 | SY | Medium |
| Northern Westchester Hospital | 1117 | NWH | Medium |
| Phelps Hospital | 1129 | PH | Medium |
| Peconic Bay Medical Center | 938 | PBC | Medium |
| Staten Island University Hospital Prince's Bay | 1737 | SIUPB | Medium |

Mount Sinai: 7 AAs. MSMC sends 6.9M, and it may be a Mount Sinai system code too.
Worth asking Healthix.

| Hospital | NYS ID | AA | Size |
|---|---|---|---|
| Mount Sinai West | 1466 | RVTH | Large |
| Mount Sinai Morningside | 1469 | STLH | Large |
| Mount Sinai South Nassau | 527 | MSSN | Large |
| Mount Sinai Brooklyn | 1324 | BIKH | Medium |
| Mount Sinai Hospital of Queens | 1639 | MSHQ | Medium |
| New York Eye and Ear Infirmary of Mount Sinai | 1460 | MSNYEE | Small |
| Mount Sinai Behavioral Health Center | 15437 | BIPD | Small |

Others:

| Hospital | NYS ID | AA | Size |
|---|---|---|---|
| Hospital for Special Surgery | 1447 | HSS | Medium |
| Calvary Hospital | 1175 | CAL | Small |
| Calvary Hospital | 10223 | CAL | Small |
| Stony Brook Eastern Long Island Hospital | 891 | ELIH | Small |

- That's 10 Large hospitals with no CCDs under any code: 7 Northwell, 3 Mount Sinai.
- Every hospital above sends ADT.
- Not a gap: One Brooklyn's Brookdale (1286) and Interfaith (1309) send CCDs under
  OBHS (about 0.75M a year, in SFDC). Their OBHSBHMC and OBHSIMC codes carry only
  ADT.
- ADT: all but one AA sends it, about 50.2M a year. A handful of extra AAs in the ADT
  file carry only a few hundred messages (LXHH, NWHS, PMHC, NYPKOCH, MSNYEE). That
  looks like code noise.

## Overall

- 117 of 194 hospitals (60%) send CCDs under their own AA: 28 of 60 Large, 48 of 78
  Medium and 41 of 56 Small.
- 32 Large hospitals show no CCDs under their own AA: 26 Healthix, 4 Rochester,
  2 Bronx. 16 of the 26 Healthix ones send under a system code, so 16 Large
  hospitals truly send none.
- Per year: about 56M CCDs and 118M ADTs on hospital AAs, plus about 51M CCDs under
  the Healthix system codes.

## Bottom line

- SFDC codes not matching PDR explains most of HealtheConnections, Hixny and a big
  part of Healthix.
  - HEC: new HECDSS codes. Handled on our side; SFDC still needs the fix.
  - Hixny: DOC codes for CCDs, plus Bassett's BAS* ADT codes.
  - Healthix: system codes NYUMC, NYPRES, NYCHH and CHSLI. MMC is used for two
    different systems and should be split.
- The real CCD gaps:
  - Northwell (15 hospitals, 7 Large)
  - most of Mount Sinai beyond MSMC (7 hospitals, 3 Large)
  - Rochester (RGHS, URMC)
  - Bronx (BronxCare, SBH), confirmed by Lisa
- Not sure how all this ties to ADT gateway payments; I'm not close to that.
