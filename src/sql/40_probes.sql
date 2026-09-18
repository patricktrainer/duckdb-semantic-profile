-- ─────────────────────────────────────────────────────────────────────────────
-- L1, step 2: which checks does THIS table warrant?
--
-- This is the step that makes the profiler adapt rather than run a fixed list.
-- Code narrows the catalog to probes that could apply to each column's discovered
-- semantic type -- cheap, deterministic, no API calls. Then one request per column
-- asks, per surviving candidate, whether running it here would actually surface
-- anything. Only the survivors get executed against real values.
--
-- The result is inspectable and filterable BEFORE you pay to run it.
-- ─────────────────────────────────────────────────────────────────────────────

-- Render a probe's text for a specific column.
CREATE OR REPLACE MACRO profile_render(template, column_name, semantic_type) AS
    replace(replace(template::VARCHAR, '{col}', column_name), '{type}', coalesce(semantic_type, 'data'));

-- Catalog entries that could apply to each column, before any model judgment.
-- Repeat calls to profile_columns cost no API requests: the responses are cached,
-- so this is a few hashes and a hash-map lookup per column.
CREATE OR REPLACE MACRO profile_candidates(tbl, n := 200, min_type_confidence := 0.6) AS TABLE
    SELECT c.column_name, c.semantic_type, c.role, c.sample_values,
           p.probe_id,
           profile_render(p.instructions, c.column_name, c.semantic_type)   AS instructions,
           json(profile_render(p.criteria, c.column_name, c.semantic_type)) AS criteria
    FROM profile_columns(tbl, n) c, profile_catalog() p
    WHERE p.scope = 'value'
      AND (p.applies_to = ['*'] OR list_contains(p.applies_to, c.semantic_type))
      -- Skip premise-dependent probes when discovery was not confident about the type.
      AND (NOT p.needs_confident_type OR c.semantic_type_confidence >= min_type_confidence);

CREATE OR REPLACE MACRO profile_selection_question(instructions) AS q_noul(
    json_object(
        'check',    instructions,
        'question', 'Is this check worth running against every value in `column.name`? Judge from `sample_values`: the check is worth running when it fits this kind of field AND it is plausible that at least some of these values fail it.'),
    json_object(
        'true',  'Worth running here: relevant to this kind of field, and some values plausibly fail it.',
        'false', json_object(
            'what',     'Not worth running here.',
            'examples', json_array(
                'the check is about a kind of field this column is not',
                'the check applies, but every sampled value clearly passes it'))));

-- Per-column probe selection: one request per column, one Noul per candidate.
CREATE OR REPLACE MACRO profile_value_probes(tbl, n := 200, min_type_confidence := 0.6) AS TABLE
    WITH cand AS (SELECT * FROM profile_candidates(tbl, n, min_type_confidence)),
    asked AS (
        SELECT column_name,
               ts_answers(
                   json_object(
                       'column',        json_object('name', any_value(column_name),
                                                    'semantic_type', any_value(semantic_type),
                                                    'role', any_value(role)),
                       'sample_values', json(any_value(sample_values))),
                   json_group_object(probe_id, profile_selection_question(instructions))) AS a
        FROM cand
        GROUP BY column_name
    )
    SELECT 'value' AS scope, c.column_name, c.probe_id,
           noul_of(a.a, c.probe_id) AS relevance,
           c.instructions, c.criteria
    FROM cand c JOIN asked a USING (column_name);

-- Row-scope probes are chosen once for the table, from the discovered schema plus
-- a few whole example rows -- a cross-column check only makes sense in the context
-- of the columns it would compare.
CREATE OR REPLACE MACRO profile_row_probes(tbl, n := 200) AS TABLE
    WITH cat AS (SELECT * FROM profile_catalog() WHERE scope = 'row'),
    asked AS (
        SELECT ts_answers(
                   json_object(
                       'table',        tbl,
                       'columns',      (SELECT to_json(list(struct_pack(
                                            name := column_name,
                                            semantic_type := semantic_type,
                                            role := role)))
                                        FROM profile_columns(tbl, n)),
                       'example_rows', json(profile_context_rows(tbl, 5))),
                   (SELECT json_group_object(probe_id,
                        q_noul(json_object(
                            'check',    instructions,
                            'question', 'Is this cross-column check worth running against every row of `table`? Judge from `columns` and `example_rows`: it is worth running when the columns needed to evaluate it are present AND some rows plausibly fail it.'),
                        json_object(
                            'true',  'Worth running: the relevant columns exist and some rows plausibly fail.',
                            'false', 'Not worth running: the columns needed are absent, or no row plausibly fails.')))
                    FROM cat)) AS a
    )
    SELECT 'row' AS scope, NULL AS column_name, c.probe_id,
           noul_of(a.a, c.probe_id) AS relevance,
           c.instructions, c.criteria
    FROM cat c, asked a;

-- The public selection view. `selected` is exactly what profile_values executes.
CREATE OR REPLACE MACRO profile_probes(
    tbl, n := 200, min_relevance := 0.5, max_per_column := 4, max_row_probes := 5,
    min_type_confidence := 0.6
) AS TABLE
    WITH all_probes AS (
        SELECT * FROM profile_value_probes(tbl, n, min_type_confidence)
        UNION ALL
        SELECT * FROM profile_row_probes(tbl, n)
    ),
    ranked AS (
        SELECT *, row_number() OVER (
                    PARTITION BY scope, column_name
                    ORDER BY relevance DESC NULLS LAST, probe_id) AS rn
        FROM all_probes
    )
    SELECT scope, column_name, probe_id, relevance,
           (relevance >= min_relevance
            AND rn <= CASE WHEN scope = 'row' THEN max_row_probes ELSE max_per_column END) AS selected,
           instructions, criteria
    FROM ranked
    ORDER BY selected DESC, relevance DESC NULLS LAST, scope, column_name, probe_id;
