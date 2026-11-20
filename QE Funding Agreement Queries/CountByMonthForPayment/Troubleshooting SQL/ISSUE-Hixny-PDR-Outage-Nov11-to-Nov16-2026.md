# Hixny: no data to PDR from Nov 11 to Nov 16, 2026

## Summary

Hixny's regular (non-Part 2) PDR feed stopped for about 5 days and 9 hours. No CCD,
TRN or LAB arrived in the regular bucket during that time. Hixny's Part 2 feed kept
working the whole time. The regular feed came back on Monday, Nov 16, and Hixny is now
replaying the backlog.

## When it started

- Last file into the regular bucket (`nyec-pdr-prod-hixny`): Wednesday, Nov 11, 2026 at
  00:08 ET (05:08 UTC).
- From the Nov 12 inventory snapshot through the Nov 16 snapshot, the bucket's file count
  stays at exactly 71,872,087. The inventory itself was working: Healthix's bucket kept
  growing in the same snapshots.

## When it ended

- First new file after the stop: Monday, Nov 16, 2026 at 09:33 ET (14:33 UTC), confirmed
  by listing S3 directly.
- Length of the outage: about 129.4 hours (5 days, 9 hours, 25 minutes). That is about
  32 times the 240-minute limit.

## How much data is likely missing

Estimated from Hixny's regular bucket over the same clock window one week earlier
(Wed Nov 4, 00:08 ET to Mon Nov 9, 09:33 ET), and checked against the 28-day daily
average before the stop:

| Data type | Same window, week before | 28-day average x 129.4 h | Likely missing |
|---|---|---|---|
| CCD | 539,614 | 501,749 | about 500K to 540K |
| LAB (ORU) | 228,764 | 247,553 | about 230K to 250K |
| TRN | 18,459 | 19,455 | about 18K to 19K |
| Total | 786,837 | 768,757 | about 770K to 790K documents |

## Part 2 worked, regular did not

| Bucket | Nov 11 to Nov 16 |
|---|---|
| `nyec-pdr-prod-hixny` (regular) | Nothing new after Nov 11 00:08 ET. Every CCD, TRN and LAB folder for Nov 12 to Nov 16 is empty. |
| `nyec-pdr-prod-hixny-part2` | Kept arriving every day. Its newest file moved forward in every snapshot, and it added about 66,000 new files (7,561,859 to 7,627,888). |

So this was a stop in Hixny's regular feed, not a PDR-wide or Hixny-wide outage.

## Recovery (as of Nov 16 afternoon)

- Since 09:33 ET today, files are arriving again. So far they all land in the `Nov/11`
  date folders. The Nov 12 to 16 folders are still empty.
- Spot check at about 11:00 ET: about 1,900 MIBDOC CCDs, 7,100 AMHSAMCH labs and 320
  AMHSAMCH TRNs had arrived in the `Nov/11` folders.
- Watch whether the replay reaches the full 770K to 790K. Also watch whether it goes into
  the right date folders. Monthly counts use the date in the S3 path, so if everything
  lands under Nov 11, the daily view will show one huge day and four empty ones.

## Why the 240-minute report did not catch it

The 240-minute query (`QEFundingAgreement240Goal/measure240minbyqe-date-range.sql`)
treats `hixny` and `hixny-part2` as one QE. Part 2 files kept arriving, so the "hixny"
QE never looked quiet. Also, a gap that is still open at the end of the range, or a day
with no arrivals at all, is not reported. Run as is, the November report would have said
Hixny met the SLA.

## How this was checked

- S3 inventory snapshots Nov 9 to Nov 16: file count and newest file per bucket.
- Hourly arrivals in the regular bucket around the stop.
- Direct read-only S3 listings of `MIBDOC` and `AMHSAMCH` (CCD, TRN and LAB, Nov 10 to
  Nov 16) for the resume time and the replay.
- Volume estimate: inventory snapshot of Nov 11 (01:00 UTC), arrival time
  (last_modified), regular bucket only, processed/error and backload excluded.
