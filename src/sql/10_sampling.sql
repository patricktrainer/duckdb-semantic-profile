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

-- Resolve explicit key columns (a name or list of names), or the primary key in
-- the order it was declared, so that `PRIMARY KEY (a, b)` and `key := ['a', 'b']`
-- give the same record keys. Views/unkeyed tables resolve to NULL; never guess.
-- Canonical schema names make case-insensitive SQL identifiers work in JSON too.
--
-- pragma_table_info knows which columns form the key but not their declared
-- order; duckdb_constraints knows the order but is keyed by catalog names. So
-- `tbl` is split into its parts and matched the way DuckDB resolves a name:
-- `db.schema.table` exactly, `x.table` as a schema in the current database or a
-- database's main schema, and a bare name in temp, then the current schema,
-- then anywhere. Only the best-ranked matches count, and they must agree on one
-- order covering exactly the columns pragma_table_info marks as key. Otherwise
-- (say, a custom search_path) fall back to column order: a wrong match can then
-- change only the order, never which columns form the key.
CREATE OR REPLACE MACRO sem_key_columns(tbl, key := NULL) AS (
    WITH schema_cols AS (SELECT * FROM pragma_table_info(tbl)),
    pk AS (SELECT list(name ORDER BY cid) FILTER (pk) AS cols FROM schema_cols),
    parts AS (
        SELECT list_transform(regexp_extract_all(tbl, '"(?:[^"]|"")*"|[^."]+'),
                   lambda x: lower(CASE WHEN x LIKE '"%' THEN replace(x[2:-2], '""', '"') ELSE trim(x) END)) AS p
    ),
    candidates AS (
        SELECT c.constraint_column_names AS cols,
               CASE len(p)
                   WHEN 3 THEN CASE WHEN lower(c.database_name) = p[1] AND lower(c.schema_name) = p[2] THEN 1 END
                   WHEN 2 THEN CASE WHEN (lower(c.schema_name) = p[1] AND c.database_name = current_database())
                                      OR (lower(c.database_name) = p[1] AND c.schema_name = 'main') THEN 1 END
                   WHEN 1 THEN CASE WHEN c.database_name = 'temp' THEN 1
                                    WHEN c.database_name = current_database() AND c.schema_name = current_schema() THEN 2
                                    ELSE 3 END
               END AS rank
        FROM duckdb_constraints() c, parts
        WHERE c.constraint_type = 'PRIMARY KEY' AND lower(c.table_name) = p[-1]
    ),
    declared AS (
        SELECT list(DISTINCT cols) AS orders FROM candidates
        WHERE rank = (SELECT min(rank) FROM candidates)
    ),
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
        WHEN key IS NULL THEN (SELECT CASE WHEN len(orders) = 1 AND list_sort(orders[1]) = list_sort(cols)
                                           THEN orders[1] ELSE cols END
                               FROM pk, declared)
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
