-- ─────────────────────────────────────────────────────────────────────────────
-- Sampling and schema introspection.
--
-- The sample is ordered by a hash of the row's own content rather than random(),
-- so the same table yields the same sample every run. That makes the response
-- cache actually hit on a re-run, and makes test fixtures reproducible.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE MACRO sem_schema(tbl) AS TABLE
    SELECT cid AS ordinal, name AS column_name, type AS declared_type
    FROM pragma_table_info(tbl);

CREATE OR REPLACE MACRO sem_sample(tbl, n := 200) AS TABLE
    SELECT row_number() OVER (ORDER BY h) AS row_id, row_json
    FROM (
        SELECT to_json(x)::VARCHAR AS row_json, hash(to_json(x)::VARCHAR) AS h
        FROM query_table(tbl) x
    )
    ORDER BY h
    LIMIT n;

-- JSON path for a column name, with embedded quotes escaped.
CREATE OR REPLACE MACRO sem_path(column_name) AS
    '$."' || replace(column_name, '"', '\"') || '"';

-- Distinct sample values per column, in first-seen order. Repeats are dropped so
-- the model sees the variety in a column rather than its most common value 200
-- times over -- variety is what exposes format drift and stray entries.
CREATE OR REPLACE MACRO sem_column_values(tbl, n := 200, per_column := 40) AS TABLE
    WITH samp AS (SELECT * FROM sem_sample(tbl, n)),
    pairs AS (
        SELECT s.ordinal, s.column_name, s.declared_type,
               json_extract(r.row_json, sem_path(s.column_name)) AS val,
               min(r.row_id) AS first_row
        FROM sem_schema(tbl) s, samp r
        GROUP BY s.ordinal, s.column_name, s.declared_type, val
    ),
    ranked AS (
        SELECT *, row_number() OVER (PARTITION BY column_name ORDER BY first_row) AS rn
        FROM pairs
    )
    SELECT ordinal, column_name, declared_type,
           to_json(list(val ORDER BY rn)) AS sample_values,
           count(*) AS distinct_values
    FROM ranked
    WHERE rn <= per_column
    GROUP BY ordinal, column_name, declared_type
    ORDER BY ordinal;

-- A few whole rows, so a column can be judged in the company it keeps.
CREATE OR REPLACE MACRO sem_context_rows(tbl, k := 3) AS
    (SELECT json_group_array(json(row_json)) FROM (SELECT row_json FROM sem_sample(tbl, 200) LIMIT k));
