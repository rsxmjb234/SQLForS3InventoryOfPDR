# AWS S3 Cost Notes & Forecast Factor (PDR)

Companion to `PDRFactSheet-PlainLanguage.sql`. This explains the cost model that
query uses and how to turn the PDR growth numbers into an AWS S3 forecast.

## What the query gives you

For each data type (CCD, TRN, Labs) it reports:
- Average document size (KB)
- Documents added per day
- GB added per month = (docs/day x avg bytes) x 30 ÷ 1,073,741,824
- Monthly storage cost added = GB/month x $0.023

## S3 pricing used (approximate, S3 Standard, us-east-1)

| Item | Rate | Notes |
|---|---|---|
| Storage | **$0.023 / GB / month** | First 50 TB tier. Drops to ~$0.022 (next 450 TB) then ~$0.021. |
| PUT requests | ~$0.005 / 1,000 | One PUT per document ingested. |
| GET requests | ~$0.0004 / 1,000 | Reads (retrieval / processing). |
| Data transfer OUT | ~$0.09 / GB | Only if data leaves AWS; intra-region is largely free. |

Storage dominates for a document archive like the PDR, so the fact sheet models
storage as the headline number and treats requests/transfer as a markup (below).

## The key idea: storage is CUMULATIVE

Documents are kept, not deleted. So each month does **not** cost a flat amount —
it ADDS a new recurring layer:

- Month 1: pay for 1x the monthly-added GB
- Month 2: pay for 2x (last month's + this month's)
- Month N: pay for N x the monthly-added GB (plus whatever was already stored)

So the storage bill grows roughly LINEARLY over time (assuming steady intake),
on top of the existing stored baseline.

## Forecast factor to apply

Take the query's **TOTAL GB/month added** figure (call it `G`), then:

1. **Baseline already stored.** Current stored bytes ÷ 1,073,741,824 = current GB.
   Current monthly storage cost = current GB x $0.023.

2. **Monthly increment.** Each month adds `G` GB -> adds `G x $0.023` per month to
   the recurring bill, forever (until data is deleted or tiered).

3. **12-month projection** of the storage line item:
   `annual_cost ~= [current_GB x 12 + G x (1+2+...+12)] x $0.023`
   The `(1+2+...+12) = 78` term captures the cumulative ramp.
   Simplified: `annual ~= [current_GB x 12 + G x 78] x $0.023`.

4. **Overhead markup for the full S3 bill (not just storage).** Based on a
   write-heavy, read-light archive, apply an **ingest/request/replication factor
   of about 1.15x–1.25x** on top of the storage number:
   - ~1 PUT per doc is cheap but non-zero.
   - If versioning or cross-region replication is ON, replication roughly
     **doubles stored bytes** for replicated prefixes -> use closer to **2.0x**
     for any data under replication.
   - Lifecycle tiering to S3-IA / Glacier can REDUCE this; if older data is
     tiered, apply a discount instead.

### Settled forecast factor (confirmed inputs)

Confirmed: **no cross-region replication**. So no replication multiplier.
Current stored bytes are taken directly as the summed object sizes from the
inventory snapshot (fact sheet's `total_*_bytes`) — effectively avg size x docs,
which is exactly what S3 bills for, so no approximation needed.

> **S3 forecast factor (about-ish):**
> `monthly storage cost = GB stored x $0.023`, and storage is **cumulative**
> (month N ≈ month 1 added GB x N, plus the existing baseline).
> Apply a flat **1.2x** overhead to cover PUT/GET requests. That's it.

12-month projection the fact sheet computes:
```
proj_12mo = [ current_GB x 12  +  monthly_added_GB x 78 ] x $0.023 x 1.2
```
- `current_GB x 12` = holding today's baseline for a year
- `monthly_added_GB x 78` = the cumulative ramp (1+2+...+12 = 78)
- `x 1.2` = request/overhead markup (no replication, so nothing more)

## If anything changes
Revisit the factor only if someone turns on **cross-region replication**
(roughly doubles replicated bytes -> use ~2.0x) or adds **lifecycle tiering**
to IA/Glacier (would LOWER the number). Neither applies today.
