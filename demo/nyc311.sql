-- Real-world data: one day of NYC 311 service requests, read straight from the
-- NYC Open Data (Socrata) API. No download step and nothing planted -- whatever
-- sem_profile finds is in the published data.
--
-- What makes it a good test, and what SUMMARIZE sees instead:
--   status vs.        22 requests left `Pending` with a closed_date set, 21 of
--   created_date/     them closed days before they were created -- three
--   closed_date       non-null VARCHARs, never compared
--   park_facility_    `Unspecified` (499 of 500) and `N/A` standing in for
--   name, facility_   missing values, next to real NULLs
--   type
--
-- The slice is fixed (2020-03-02) and ordered by unique_key, so a rerun fetches
-- the same 500 rows. `location` is a nested struct that only repeats latitude and
-- longitude, so it is dropped. unique_key identifies a request but is not a
-- declared PRIMARY KEY, so pass it as `key`:
--
--   .read demo/nyc311.sql
--   SELECT * FROM sem_cost('sr311', rows := 100);
--   SELECT * FROM sem_profile('sr311', rows := 100, key := 'unique_key');

CREATE OR REPLACE TABLE sr311 AS
SELECT * EXCLUDE (location)
FROM read_json_auto('https://data.cityofnewyork.us/resource/erm2-nwe9.json?$where=created_date%20between%20%272020-03-02T00:00:00%27%20and%20%272020-03-03T00:00:00%27&$order=unique_key&$limit=500');
