my goal is to understand how many total documetns are in PDR
by QE 
by looking at inventory snapshots
review every 10 days snapshot
do this for the last 100 days.

in a way that excludes any data you see in this file: FindingOrphanSources\2026-09-04-REPORT on All sources contributing to PDR not in Verato.csv

those sources should not count, because they will be double counted.

output example
date,qe,ccd,trn
6/1/2026,Healthix,12,20
6/1/2026,Bronx,22,23
6/1/2026,rochester,23,324
6/2/2026,Healthix,12,20
6/2/2026,Bronx,22,23
6/2/2026,rochester,23,324

