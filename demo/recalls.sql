-- Real-world data: FDA food recall enforcement reports, read straight from the
-- openFDA JSON API. No download step and nothing planted -- whatever sem_profile
-- finds is in the published data.
--
-- What makes it a good test, and what SUMMARIZE sees instead:
--   product_quantity   free text: '480/20 ib cases', 'Approximately 1204 total
--                      units for all products' -- just a non-null VARCHAR
--   *_date             YYYYMMDD strings, so status vs. dates is never checked
--   city/state/        address fields that can contradict each other
--   country/postal_code
--   reason_for_recall, narrative text, lot codes and state lists packed into
--   distribution_pattern, single fields
--   code_info
--
-- The API caps a request at 1000 rows; page with &skip=N for more. Sorting by
-- report_date makes a rerun fetch the same rows until new recalls are posted.
--
--   .read demo/recalls.sql
--   SELECT * FROM sem_cost('recalls');
--   SELECT * FROM sem_profile('recalls', rows := 100);

CREATE OR REPLACE TABLE recalls AS
SELECT * EXCLUDE (openfda)   -- nested struct of cross-reference ids; empty for most food recalls
FROM (
    SELECT unnest(results, recursive := true)
    FROM read_json_auto('https://api.fda.gov/food/enforcement.json?limit=500&sort=report_date:desc')
);
