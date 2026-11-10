# Hospital CCD/ADT vs SPARCS, QE by QE (November 2026, second look)

We run month over month, and I have only recently started to look at this vs SPARCS.

Here is what today looks like:
1. Still early days. The data is moving around and will keep moving.
2. We definitely have hospitals that don't send CCDs.
3. SFDC and what we see in the wild still don't line up, but we can now see past it.

This covers the 194 participating hospitals that SPARCS knows, grouped by assigning
authority (AA). The numbers are 28 days of data scaled to a year, so treat them as
directional. ADT is now in, from the ADT counts file (Aug-Oct 2026).

What changed since last time: for HealtheConnections we now map the old SFDC codes to
their current AAs. We also pick up the AA each hospital actually uses in the ADT file,
and for Hixny we look for the DOC AA. That moved HealtheConnections from 0% to
nearly all hospitals.

Overall: 117 of 194 hospitals (60%) send CCDs. That is 28 of 60 Large, 48 of 78
Medium and 41 of 56 Small. 32 Large hospitals show no CCDs under their own AA:
26 Healthix, 4 Rochester, 2 Bronx. 16 of the 26 Healthix ones send CCDs under a
system code (see Healthix). Per year: about 56M CCDs and 118M ADTs on hospital AAs,
before the Healthix system codes (about 51M more).

Percentages below are the share of each QE's hospital AAs that send CCDs. Part 2
(substance-use) AAs are left out.

## Bronx: 33%

- 3 hospital AAs in SFDC: MMC (Montefiore), BXLEB and SBH. 1 of 3 sends CCDs.
- Montefiore (MMC) sends about 4.1M CCDs, 8.2M TRN and 10.8M LAB a year.
- Watch out: SFDC uses MMC for two different systems, Montefiore under Bronx and
  Maimonides under Healthix. Only the PDR bucket tells them apart. The ADT file
  splits them correctly.
- BXLEB (BronxCare) and SBH send no CCDs in any bucket, but both send TRN and LAB.
  Lisa talked to them and confirmed they don't get CCDs from either.
- ADT: about 9.3M a year across the three.

## HEALTHeLINK: 67%

- 9 hospital AAs, and 6 send CCDs: CHSEPI, KHSEPI, UPMCEP, RPCI, BRTRND and NFMMC.
  About 4.7M CCDs a year.
- ECMC, UMMC and MEDINA send no CCDs.
- ECMC's CCDs may be coming in under KHSEPI, which is where the ADT file puts
  ECMC. Needs confirming.
- Wyoming County (WCCHS) is also listed under Rochester. It sends CCDs, so counting
  it makes 7 of 10.
- ADT: everyone but UMMC sends it, about 18.6M a year.

## HealtheConnections: 95% (was 0%)

- The hunch was right. When they moved to HECDSS they got all new AAs, and those
  are not in SFDC. Once the old SFDC codes are mapped to the new ones, 38 of 40 AAs
  send CCDs: 54 of 55 hospitals, about 29.6M CCDs a year. That is the largest of
  any QE.
- Only St. Joseph's Medical Center sends none. Its AAs send ADT only.
- 5 AAs in active use are not in HEC's own lookup and only show up in the ADT
  file: CROUSE, UHS, ST-LUKES-CORN, WEST-MIDHUDSON-3 and HAHV-KINGSTON-3. Between
  them they send about 5M CCDs a year.
- The -2 codes are Part 2 (substance-use) feeds. They are small by design and not
  counted.
- ADT: about 20.9M a year.
- SFDC itself still has the old codes. We fix them on the way in; SFDC should be
  updated at the source.

## Hixny: 4% or 100%, depending how you count

A very mixed story.

- Why 4%: Hixny has 26 AAs on file in SFDC, and only one shows any CCDs. That one is
  MMGKIDSK, a tiny Massena feed.
- Why 100%: they told us they code CCDs to DOC sources (MIBDOC, AMHSAMCHDOC,
  PAPLDOC and similar) that aren't in SFDC. With the DOC suffix, every Hixny
  hospital sends CCDs: 26 DOC AAs, about 3.6M a year. HealthAlliance and
  Margaretville send theirs through HealtheConnections.
- The pin from last time is real. ADT and TRN come in on the base AA (MIB) and CCDs
  on the DOC AA (MIBDOC), so one hospital has two AAs. Bassett goes further: its
  ADTs arrive under BAS* codes (BASMIBO, BASAOFO, BASCRHO, BASLFHO, BASOCO) that
  aren't in SFDC either.
- ADT: about 5.2M a year. Several SFDC codes (WMC, RRHCPH, RRHGH, RRHMH,
  WMCBSMGGSH) send TRN but no ADT, so their ADT must be arriving on another code.

## Rochester: 0%

- 6 hospital AAs, and none send CCDs.
- This one is not a code mismatch. RGHS (10 hospitals) and URMC (6 hospitals) send
  plenty of ADT and TRN, just no CCDs. URMC's ADT comes in under URMCEPIC, which
  isn't in SFDC.
- ADT: about 22.0M a year, URMCEPIC 15.2M and RGHS 5.2M.
- ACH and CPH send almost nothing, because Auburn and Canton-Potsdam send under
  HealtheConnections (and Hixny DOC) codes instead. Counting those, 7 of the 23
  hospitals SFDC lists under Rochester get CCDs into PDR, and all but one come
  through another QE.

## Healthix: 23% or 64%, depending how you count

- Why 23%: 75 hospital AAs in SFDC, and 17 send CCDs under their own code. About
  13.9M a year. Mount Sinai (MSMC) alone is 6.9M. Maimonides (MMC) sends only
  0.2M; the Bronx MMC volume belongs to Montefiore.
- Why 64%: four systems send CCDs under one system-wide code that isn't in SFDC
  (it's the HECDSS story again). Counting them, 48 of 75 AAs:
  - NYUMC, NYU Langone (5 AAs): about 25.2M CCDs a year, plus 12.5M TRN and 27.4M LAB
  - NYPRES, NewYork-Presbyterian (9 AAs): about 17.4M
  - NYCHH, NYC Health + Hospitals (11 AAs): about 7.1M
  - CHSLI, Catholic Health LI (6 AAs): about 1.4M
- These are system codes, so we can't tie the CCDs to a specific hospital, and some
  of the volume is likely from their practices rather than the hospitals.
- Who really sends nothing: Northwell (15 AAs, including LIJ, North Shore, Lenox
  Hill, SIUH and South Shore), most of Mount Sinai other than MSMC (7 AAs, including
  West, Morningside and South Nassau), plus HSS, Calvary, Stony Brook Eastern LI and
  two One Brooklyn sites. That's 10 Large hospitals with no CCDs under any code.
- MSMC may also be a Mount Sinai system code; worth asking.
- ADT: all but one AA sends it, about 50.2M a year. A handful of extra AAs in the
  ADT file carry only a few hundred messages (LXHH, NWHS, PMHC, NYPKOCH, MSNYEE).
  That looks like code noise.

## Bottom line

- SFDC codes not matching PDR was most of the HealtheConnections story. It's now
  handled on our side, but SFDC still needs the fix.
- For Hixny, SFDC needs the DOC codes, and for Bassett its BAS* ADT codes.
- For Healthix, SFDC needs the system codes (NYUMC, NYPRES, NYCHH, CHSLI). MMC
  is used for two different systems and should be split.
- The real CCD gaps are Northwell and most of Mount Sinai (Healthix), Rochester
  (RGHS, URMC), and Bronx (BronxCare, SBH). Bronx is confirmed by Lisa.
- Not sure how all this ties to ADT gateway payments; I'm not close to that.
