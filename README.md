# duckdb-semantic-profile

Profile what the **values** in a table actually mean, from inside DuckDB.

`SUMMARIZE`, `pandas.describe()` and ydata-profiling all describe the *shape* of
data: types, ranges, quantiles, null and distinct counts. They are structurally
blind to what the values mean. This extension asks the other question.

```sql
LOAD semantic_profile;
SELECT * FROM sem_profile('shipments');
```

```
scope   column_name   probe_id                                                      rows_flagged  examples                                                                        example_rows
value   shipped_at    sentinel_used_as_value                                        4             [9999-12-31, '']                                                                [13, 12, 3, 20]
value   customer      placeholder_or_test_value                                     2             [Test Company, Asdf Asdf]                                                       [9, 19]
value   notes         placeholder_or_test_value                                     2             [lorem ipsum dolor, asdf]                                                       [9, 19]
row     postal_code   geo_inconsistent, internally_contradictory, row_is_test_data  2             ['postal_code=SW1A 1AA; country=US', 'postal_code=EC1A 1BB; country=US']        [17, 11]
row     status        internally_contradictory, status_timeline_inconsistent        2             ['status=shipped; shipped_at=', 'status=shipped; notes=awaiting carrier scan']  [3, 20]
value   email         multiple_values_in_one_field                                  1             [orders@delta.com; billing@delta.com]                                           [2]
value   address       operational_note_in_data_field                                1             [DO NOT SHIP - see ticket 4412]                                                 [12]
value   customer      mojibake                                                      1             [CafÃ© Lumière SARL]                                                            [18]
row     category      category_product_mismatch, internally_contradictory           1             ['category=Garden Tools; product_name=Blue Cotton T-Shirt']                     [1]
column  notes         sensitive_personal_data                                       ·             ·                                                                               ·
column  weight        unit_unrecoverable                                            ·             ·                                                                               ·
```

That is real output from `demo/messy.sql` (jev-1.13.0), not an illustration,
abridged to the findings for the planted defects.
Not one of those findings moves a single number in `SUMMARIZE`: the types are
right, the ranges are plausible, nothing is NULL, and no distinct count looks odd.

Judgments come from [TypeSafe](https://docs.typesafe.ai)'s System One model (Jev),
which returns calibrated typed answers and probabilities rather than free text.

## What it can see that a statistical profiler cannot

| | Example | Why `SUMMARIZE` misses it |
|---|---|---|
| Fake data that looks real | `customer = 'Asdf Asdf'`, `city = 'Test City'` | Statistically unremarkable strings |
| Values that aren't what the column claims | `email` holding `n/a` | Still a VARCHAR, still non-null |
| Unit and format drift | `12 kg` next to a bare `26.4` | Both are values in the same column |
| **Cross-column contradictions** | `country='US'` with `postal_code='SW1A 1AA'` | Column-at-a-time by construction |
| | `status='shipped'` with `shipped_at=''` | |
| PII hiding in free text | a note quoting someone's SSN | No column is named `ssn` |
| Process notes in data fields | `address = 'DO NOT SHIP - see ticket 4412'` | A perfectly normal-length string |
| Opaque codes | `st` holding `A`/`C`/`P` | Three distinct values, as expected |

## How it adapts to the table

Four steps. The second is what makes it adapt rather than run a checklist; the
fourth is what makes a row-level finding say what is wrong.

1. **Discover** — one request per column. What does this column actually hold,
   judged from its values, its neighbours and a few whole rows? Yields a semantic
   type, a role, and flags for name/value mismatch, PII, format drift, sentinels
   and opaque encodings. The column *name* is treated as a hint that may be lying.
2. **Select** — one request per column. Code narrows the 20-probe catalog to
   probes that could apply to each discovered semantic type, then asks, per
   candidate, whether running it *here* would surface anything. Only survivors run.
   `sem_probes()` shows you this before you pay for it.
3. **Execute** — one request per row. The state is the whole row; the questions are
   every selected value probe across every column *plus* every row-level coherence
   check. Answers are independent, so the cross-column checks add only their own
   question text to a request that is being sent anyway.
4. **Attribute** — one small request per row that a row-level check scored 0.5 or
   above. Which single field is most responsible, as a choice over the row's own
   columns plus `no_conflict`? The top two fields name the problem. A check that
   answers `no_conflict` when made to point at something is dropped, as is one
   whose field already has a value finding on that row. What remains is grouped
   by field, so a defect repeated across rows usually reads as one finding: on
   NYC 311 data, 11 rows of it came back as one. It can split when the model
   blames different fields on different rows. `sem_row_fields()` shows the answers.

Cost is therefore `2 × columns + rows` plus the attribution requests, not
`columns × rows`. A 20-column table at 500 sampled rows is ~540 requests, plus
one per row a row-level check suspects; on the datasets tried so far that has
been 3-24% of `rows × 5`, which `sem_cost()` reports as a ceiling.

```sql
SELECT * FROM sem_cost('shipments');   -- dry run, makes no API calls
```

## Install

The extension is in DuckDB's
[community extensions](https://github.com/duckdb/community-extensions/tree/main/extensions/semantic_profile)
repository, so no build is needed. It needs DuckDB **v1.5.6** (the C API build is
version-pinned).

```bash
export TYPESAFE_API_KEY=...   # or: SELECT sem_config('api_key_file', '~/.typesafe-key');
duckdb
```

```sql
INSTALL semantic_profile FROM community;
LOAD semantic_profile;
SELECT * FROM sem_profile('shipments');
```

The key is read from the environment or a file, never from SQL, where it would
end up in query logs and shell history.

### Building from source

Needs Rust, Python 3 and DuckDB **v1.5.6**.

```bash
git clone --recursive git@github.com:patricktrainer/duckdb-semantic-profile.git
# already cloned without --recursive:  git submodule update --init

brew upgrade duckdb        # if you are on an older 1.5.x
make configure && make debug
export TYPESAFE_API_KEY=...   # or put it in .env, which is gitignored
duckdb -unsigned
```

`extension-ci-tools` is a submodule; `make configure` needs it, and it also builds
a venv under `configure/` and downloads a matching DuckDB for the test runner.

```sql
LOAD './build/debug/semantic_profile.duckdb_extension';
.read demo/messy.sql
SELECT * FROM sem_profile('shipments');
```

## Where the macros go

The pipeline is SQL macros, and `CREATE MACRO` is ordinary DDL — on a database
file it would persist into that file. Loading an extension should not modify
someone's database, so the macros install automatically **only on an in-memory
database**, where nothing persists.

To profile a database file, open DuckDB in memory and attach it read-only:

```sql
LOAD semantic_profile;
ATTACH '/path/to/warehouse.duckdb' AS db (READ_ONLY);

SELECT * FROM sem_cost('db.main.orders', rows := 50);
SELECT * FROM sem_profile('db.main.orders', rows := 50);
```

`LOAD` before `ATTACH`, and qualified table names work throughout.

Stay in the in-memory database rather than `USE`-ing the attached one. The macros
live in `memory.main`, so after `USE db` every `sem_*` call fails with
`Table Function with name sem_profile does not exist`, and qualifying it as
`memory.main.sem_profile` does not help, because the macros it calls are looked
up the same way. Either `USE memory` and qualify your table names, or keep the
macros on the search path:

```sql
USE db;
SET search_path = 'db.main,memory.main';
```

On a file-backed or read-only database the macros are skipped, `LOAD` still
succeeds, the scalar functions still work, and `sem_status()` says why. Set
`SEMANTIC_PROFILE_INSTALL_MACROS=1` before `LOAD` to install them into that catalog
anyway, or run the script `sem_sql()` returns on your own connection.

## API

**Pipeline** — each takes a table or view name.

| | |
|---|---|
| `sem_profile(tbl, threshold := 0.7, rows := 100, n := 200, key := NULL)` | every finding, column-, value- and row-level |
| `sem_columns(tbl, n := 200)` | what each column actually is |
| `sem_probes(tbl, …)` | which checks were chosen, and their relevance |
| `sem_values(tbl, rows := 100, …)` | raw per-row judgments, long form |
| `sem_report(tbl, threshold := 0.7, …, key := NULL)` | findings aggregated per probe (value) or per field (row), with evidence |
| `sem_row_fields(tbl, …, key := NULL)` | for each suspect row, the fields a row-level check blames |
| `sem_findings(tbl, …, key := NULL)` | raw threshold crossings, before report retractions/grouping |
| `sem_report_rows(tbl, …, key := NULL)` | every flagged/review record retained by the report, with keys and finding IDs |
| `sem_cost(tbl, …)` | dry run: request and token estimate, attribution ceiling |
| `sem_catalog()` | the probe catalog |

**Primitives** — TypeSafe judgments as plain SQL, useful on their own.

```sql
SELECT ts_noul(to_json(t), 'Is this shipment address deliverable?') FROM shipments t;
SELECT ts_choice(notes, 'What is this note about?', {'delay':'…','damage':'…','other':'…'}) FROM shipments;
SELECT ts_score(notes, 'How urgent is this?', ['routine','soon','immediate']) FROM shipments;
```

`ts_ask(state, questions)` is the one function that reaches the network: N questions,
one request. `ts_noul` / `ts_choice` / `ts_score` are one-shot wrappers over it; inside
the pipeline questions are always batched instead.

**Admin** — `sem_config(k, v)`, `sem_settings()`, `sem_stats()`,
`sem_reset_stats()`, `sem_status()`, `sem_sql()`.

## Reading the output

Judgments are **probabilities, not verdicts**. `threshold` is an argument, and
changing it re-reads cached judgments rather than re-asking — so re-slicing a
report costs nothing.

`sem_report` also reports `needs_review`: rows whose probability lands near 0.5.
A Noul near 0.5 means genuinely uncertain, not "medium severity".

That band earns its keep. On the demo's `weight` column — `12 kg` alongside a bare
`26.4` — `unit_ambiguous` scores the bare numbers **0.57 and 0.50** and every value
that states its unit **0.02**. Clean separation, but it stops short of asserting a
defect, because the unit arguably *is* inferable from the rest of the column. A
binary classifier would have to pick a side and be wrong either way; here the two
rows land in `needs_review` and a person decides.

Every finding carries evidence — `examples` holds the actual offending values,
`example_rows` their sample ordinals and `example_keys` their keys in your table.

A row-level finding has no single offending value, so it names the field instead:
`column_name` is the field most blamed, `examples` shows it with the field it
conflicts with (`postal_code=SW1A 1AA; country=US`), and `probe_id` lists every
check that noticed. Rows it is less sure of — scored from 0.5 up to `threshold`,
but at least 0.3 above what that check typically scored — are listed separately
as `rows_to_review` / `review_rows`. On NYC 311 data that is how a real defect
surfaced: 11 requests left `Pending` with closed dates, scored ~0.6 against a
typical 0.1, and never reached 0.7.

`example_rows` and `review_rows` are positions in the sample, not your table's
keys. `example_keys` and `review_keys` give the same rows, in the same order, by
the table's own key: its `PRIMARY KEY` (including composite keys) if it declares
one, or the column name or list of column names you pass as `key`. The demo table declares none, so:

```sql
SELECT column_name, example_rows, example_keys
FROM sem_profile('shipments', rows := 20, key := 'id')
WHERE scope = 'row';
```

```
column_name   example_rows  example_keys
postal_code   [17, 11]      [5, 12]
status        [3, 20]       [15, 7]
category      [1]           [6]
customer      [15]          [1]
```

With no primary key and no explicit `key` (for example, a view), the key columns
are NULL. Unknown column names, empty key lists, repeated columns, and NULL list
entries are errors. Names are resolved case-insensitively, as in SQL.
`SELECT sem_key_columns('shipments', 'id')` checks the selection locally without
making API requests.

Single-column keys come back as `VARCHAR`; cast them to join to your table.
Composite keys come back as JSON objects encoded as `VARCHAR`, preserving names
and value types. For example, `key := ['order_id', 'line_number']` might return
`{"order_id":"ORD-1005","line_number":2}`. Components come in the order of the
supplied list or, for a primary key, the order it was declared in, so a table
declared `PRIMARY KEY (order_id, line_number)` gives the same `row_key` whether
the key is detected or named. (If the declared order cannot be pinned to one
table, such as under a custom `search_path`, a detected key falls back to column
order; name it explicitly to be sure.)
If any component is NULL, the entire `row_key` is NULL. Explicit keys are not
checked for uniqueness: choose non-null columns that identify a record. Findings
are never merged just because their key values match.

### Drill into a report

`example_keys` and `review_keys` contain at most five records each.
**`sem_report_rows()` returns all sampled records represented by the report**,
with the same retractions, duplicate suppression and field grouping. Its
`disposition` is `flagged` or `review`, `probe_ids` is a list of contributing
checks, and `row_json` contains the complete sampled record.

```sql
SELECT d.row_key, d.disposition, d.probe_ids, d.evidence, s.*
FROM sem_report_rows('shipments', rows := 20, key := 'id') d
JOIN shipments s ON s.id = d.row_key::INTEGER
WHERE d.scope = 'row' AND d.column_name = 'postal_code';
```

`sem_profile()`, `sem_report()` and `sem_report_rows()` share a `finding_id`, so
an application can open a summary finding and fetch its records by that ID.
Use the same table name, thresholds, sample sizes and other profiling options
for summary and detail. The ID identifies a report group, not a record or saved
run: it uses the supplied table name, scope, field and (for value/column findings)
probe. A row group's ID survives changes in its contributing probes, but changes
if attribution moves the group to another field. Renaming the table or using a
different qualified name also changes IDs. Column findings have no detail rows.

For composite keys, extract the components to join:

```sql
SELECT d.disposition, d.evidence, s.*
FROM sem_report_rows('shipments', rows := 20, key := ['id', 'order_ref']) d
JOIN shipments s ON s.id = (d.row_key::JSON->>'id')::INTEGER
                AND s.order_ref = (d.row_key::JSON->>'order_ref');
```

`sem_findings()` still returns raw threshold crossings, including judgments that
the report later retracts or consolidates. `sem_row_fields()` exposes attribution
and its `retracted` flag. Both accept the same `key` argument. Selecting a key
changes only the output; it does not change model requests or invalidate cached
judgments. Keep the source data unchanged between profiling and drill-down, or
materialize the detail results to retain a snapshot.

**NULL is never probed.** A SQL NULL is absence expressed correctly, so asking
"is this a placeholder?" about one invites a yes — exactly backwards, since
`sentinel_used_as_value` exists to find values that *stand in* for absence. Value
probes are pruned per row where the column is NULL, which also costs nothing in
cache reuse (state differs per row regardless) and saves the tokens. A value that
does stand in for absence — `n/a`, `-1`, `''` — is still caught.

**Probes whose premise is the semantic type are gated on confidence.** If discovery
is only 0.51 sure that `product_name` holds product *codes*, then asking "is
`Steel Bracket` a product code?" produces a confident wrong answer on every row.
Those probes are skipped below `min_type_confidence` (default 0.6) rather than
allowed to launder a shaky classification into 20 findings.

## Settings

Override with `SELECT sem_config(key, value)`, or the environment as
`SEMANTIC_PROFILE_<KEY>` / `TYPESAFE_<KEY>`.

| key | default | |
|---|---|---|
| `api_key_file` | — | path to a file holding the key |
| `model` | `jev-latest` | |
| `cache_path` | `~/.cache/duckdb-semantic-profile/cache.jsonl` | |
| `offline` | `false` | serve from cache only; a miss is a hard error |
| `max_requests` | `2000` | per-process cap; exceeding it is an error, not a warning |
| `concurrency` | `8` | |
| `timeout_secs` | `60` | |

**The API key is never settable from SQL.** `sem_config('api_key', ...)` is
rejected, because a key passed through SQL lands in query logs, `duckdb_queries()`
and shell history. Supply it as `TYPESAFE_API_KEY` in the environment, or point
`api_key_file` at a file containing it.

DuckDB Secrets would be the right home for it, but the C extension API exposes no
secrets interface and secret values read back from SQL are redacted, so an
extension built this way cannot reach them.

**Caching.** Responses are content-addressed on `sha256(model ‖ state ‖ questions)`
and appended to a JSONL file. Sampling is ordered by a hash of row content rather
than `random()`, so a re-run hits the cache instead of re-billing. The cache is
plain text on purpose: it is readable, diffable, and doubles as a test fixture.

**Cost control.** `sem_cost()` dry-runs, `sem_probes()` shows what will run,
`max_requests` is a hard stop, and sampling is on by default — `rows` and `n` are
caps you raise deliberately.

## Extending it

The probe catalog and every question is SQL, not compiled into the binary:

```sql
SELECT instructions, criteria FROM sem_catalog() WHERE probe_id = 'embedded_pii';
SELECT sem_sql();   -- the whole macro layer
```

Add your own probes by redefining `sem_catalog()` to `UNION ALL` your rows onto
it. Scope is `value` (per value, with `{col}` and `{type}` substituted) or `row`
(per whole row).

## Tests

```bash
cargo test        # request building, response parsing, cache keying, budget
make test_debug   # full SQL surface, offline against a fixture cache: no key, no network
```

`test/fixtures/*.jsonl` hold real jev-1.13.0 responses frozen from live runs. The replay test sets `offline`, where a cache miss is a hard error — so it
cannot quietly pass on invented answers.

With a key, `demo/acceptance.py` checks the end-to-end claim: it plants 12 defects in
`demo/messy.sql` and asserts the profiler finds each one, joined back on the table's
own `id`.

```
12/12 planted defects detected at threshold 0.7
country/postcode contradict    [5, 12]  reported  row findings: row:postal_code
shipped with no ship date      [7, 15]  reported  row findings: row:notes, row:status
product/category mismatch      [6]      reported  row findings: row:category
bare numbers (26.4, 35.2): up to 0.6   values stating kg: up to 0.02
unflagged rows: 1, 2, 4, 10, 11, 13, 16, 18
```

It also checks that dropping and grouping row findings never loses a planted
defect. On that run the "shipped with no ship date" rows came back as two
findings rather than one: row 7 blamed `notes` ("awaiting carrier scan" beside
`status = shipped`), row 15 blamed `status`.

## Notes and limits

- The extension is built against the **unstable** DuckDB C API, so a binary loads
  only into the DuckDB version it was built for (currently v1.5.6).
- Loading the extension never writes to your database. See **Where the macros go**.
- Sampling uses `ORDER BY hash(row) LIMIT n`, which reads the whole table. For very
  large tables, profile a pre-sampled view.
- `sem_columns` is re-evaluated by the later stages. That costs no API requests
  — repeat calls are cache hits, and concurrent duplicates are collapsed by a
  single-flight lock so a cold cache cannot double-bill — but it does re-hash.
- `row_is_test_data` is broad by design and fires readily on synthetic data (the
  demo table is entirely fabricated, so it fires on much of it). Treat it as a
  smell, not a verdict, or drop it from the catalog.
- Judgment quality is TypeSafe's, not this extension's. Validate on your own data
  before wiring any of it into an automated decision.
- **The response cache stores the sampled values in plaintext**, at
  `~/.cache/duckdb-semantic-profile/cache.jsonl` by default. Profiling real data puts real
  data there. Point `cache_path` somewhere appropriate, or delete it afterwards.
- Profiling sends sampled values to `api.typesafe.ai`. `sem_cost()` tells you
  how much will go, and `sem_probes()` what will be asked, before anything does.

## License

MIT. See [LICENSE](LICENSE).
