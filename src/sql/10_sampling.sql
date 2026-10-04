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

-- Resolve explicit key columns (a name or list of names), or every primary-key
-- column in schema order. Views/unkeyed tables resolve to NULL; never guess.
-- Canonical schema names make case-insensitive SQL identifiers work in JSON too.
CREATE OR REPLACE MACRO sem_key_columns(tbl, key := NULL) AS (
    WITH schema_cols AS (SELECT * FROM pragma_table_info(tbl)),
    requested AS (
        SELECT CASE
            WHEN key IS NULL THEN NULL::VARCHAR[]
            WHEN json_type(to_json(key)) = 'VARCHAR' THEN [json_extract_string(to_json(key), '$')]
            WHEN json_type(to_json(key)) = 'ARRAY' THEN
                CASE WHEN EXISTS (SELECT 1 FROM json_each(to_json(key)) WHERE type <> 'VARCHAR' OR type IS NULL)
                     THEN error('key: expected a column name or a non-empty list of column names')
                     ELSE json_extract_string(to_json(key), '$[*]')::VARCHAR[] END
            ELSE error('key: expected a column name or a non-empty list of column names')
        END AS names
    ),
    resolved AS (
        SELECT r.ordinal, r.name AS requested_name, s.name
        FROM requested, unnest(names) WITH ORDINALITY AS r(name, ordinal)
        LEFT JOIN schema_cols s ON lower(s.name) = lower(r.name)
    )
    SELECT CASE
        WHEN key IS NULL THEN (SELECT list(name ORDER BY cid) FILTER (pk) FROM schema_cols)
        WHEN len(names) = 0 THEN error('key: expected a non-empty list of column names')
        WHEN EXISTS (SELECT 1 FROM resolved WHERE name IS NULL)
            THEN error('key: no column `' || (SELECT requested_name FROM resolved WHERE name IS NULL ORDER BY ordinal LIMIT 1) || '` in ' || tbl)
        WHEN (SELECT count(*) <> count(DISTINCT name) FROM resolved)
            THEN error('key: duplicate column names')
        ELSE (SELECT list(name ORDER BY ordinal) FROM resolved)
    END
    FROM requested);

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

-- Single-column keys keep their original VARCHAR representation. Composite
-- keys are JSON objects with typed values, so delimiters cannot cause collisions.
-- Any missing component means the record has no usable key.
CREATE OR REPLACE MACRO sem_record_key(row_json, key_columns) AS
    CASE
        WHEN key_columns IS NULL OR len(key_columns) = 0 THEN NULL
        WHEN len(list_filter(list_transform(key_columns, lambda c: json_extract(row_json, sem_path(c))),
                             lambda v: v IS NULL OR json_type(v) = 'NULL')) > 0 THEN NULL
        WHEN len(key_columns) = 1 THEN json_extract_string(row_json, sem_path(key_columns[1]))
        ELSE to_json(map(key_columns, list_transform(key_columns, lambda c: json_extract(row_json, sem_path(c)))))::VARCHAR
    END;

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
