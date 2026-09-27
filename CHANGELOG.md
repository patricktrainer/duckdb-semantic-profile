# Changelog

## 0.2.0 — 2026-09-27

Row-level findings now say what is wrong with a row, not just that something is.

### Breaking

- **Row findings in `sem_report` and `sem_profile` changed shape.** `column_name`
  was NULL and is now the field the finding blames. `probe_id` was one probe and
  can now be several, comma-separated (`geo_inconsistent, internally_contradictory`),
  because one finding covers every probe that noticed the same rows. A filter like
  `WHERE scope = 'row' AND probe_id = 'geo_inconsistent'` should become
  `probe_id LIKE '%geo_inconsistent%'`. Value- and column-level findings are unchanged.
- **`sem_profile` has three more columns**: `example_rows`, `rows_to_review`,
  `review_rows`. Queries that name their columns are unaffected; `SELECT *` into a
  table with the 0.1.0 shape, or reading columns by position, is not.
- **Profiling makes more requests**: one small request (~1.5k tokens) per row a
  row-level check scores 0.5 or above: 17 and 49 per 100 rows on NYC 311 and FDA
  recall data, 24 for the 20 rows of the deliberately defect-dense demo table.

### Added

- **Step 4, attribution** (`sem_row_fields`): each suspect row is asked which
  field is most responsible. Findings name that field and show the values
  involved (`postal_code=SW1A 1AA; country=US`), are grouped by field across
  probes, and drop judgments that back off to `no_conflict` or only restate a
  value finding on the same row.
- **Borderline row findings**: scores from 0.5 up to `threshold` that sit at least
  0.3 above that probe's median are listed as `rows_to_review` / `review_rows`
  (tunable as `review_floor` / `review_lift`). On NYC 311 data this surfaced 11
  requests left `Pending` with closed dates, which scored ~0.6 and never reached 0.7.
- **`example_rows` in `sem_profile`**, so a finding points at its rows.
- **`attribution_requests_max` in `sem_cost`**: a ceiling for step 4, which
  depends on scores that do not exist before the run.
- **`demo/recalls.sql`**: FDA food recalls straight from the openFDA API.

### Fixed

- **`sem_cost` underestimated tokens 2–5x.** Recalibrated on the usage recorded in
  four real runs; now 103–123% of actual.
- **`demo/acceptance.py`** also checks that the report layer keeps every planted
  cross-column defect.

## 0.1.0 — 2026-09-18

First release, published to DuckDB community extensions.
