
The goal is to write a query that will find any instance where a QE failed to submit data for a period of 240 minutes.


For purposes of performance monitoring and contractual compliance, failure to submit any required data type to the Primary Document Repository (PDR), (E.g. CCD, TRN, or ORU) for a continuous 240-minute period shall constitute an outage event.   

the table scheme is in #tabledescription.txt
an exampel query that find the Qualified entity by parsing data in the S3 path is #last10daysv2.sql

you want to limit the scope of this query to 'yesterday' becuase we want a full day of data.

be sure to take full advantage of the S3 Hives, to minimize the GB of data pulled.

be sure to comment your code to explain the goal, including the goal as crafted above.
