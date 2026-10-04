-- ─────────────────────────────────────────────────────────────────────────────
-- L1, step 3: run the selected probes against real values.
--
-- One request per row. The state is the whole row, and the questions are every
-- selected value probe across every column PLUS every selected row probe.
-- Because state is what costs tokens and answers are independent of each other,
-- bundling them this way makes the cross-column coherence checks effectively
-- free: they ride along in a request the value probes were paying for anyway.
--
-- Cost is therefore ~ (2 x columns) for discovery and selection, + one request
-- per sampled row -- not one per column per row.
-- ─────────────────────────────────────────────────────────────────────────────

-- The execution plan: selected probes, numbered. Question ids are positional so
-- that column names can contain anything without breaking JSON paths.
CREATE OR REPLACE MACRO sem_plan(
    tbl, n := 200, min_relevance := 0.5, max_per_column := 4, max_row_probes := 5,
    min_type_confidence := 0.6
) AS TABLE
    SELECT 'p' || row_number() OVER (ORDER BY scope, column_name NULLS FIRST, probe_id) AS qid,
           scope, column_name, probe_id, instructions, criteria
    FROM sem_probes(tbl, n, min_relevance, max_per_column, max_row_probes, min_type_confidence)
    WHERE selected;

-- Per-value and per-row judgments, in long form: one row per (row, probe).
CREATE OR REPLACE MACRO sem_values(
    tbl, rows := 100, n := 200, min_relevance := 0.5, max_per_column := 4, max_row_probes := 5,
    min_type_confidence := 0.6
) AS TABLE
    WITH plan AS (SELECT * FROM sem_plan(tbl, n, min_relevance, max_per_column, max_row_probes, min_type_confidence)),
    -- Ask a value probe only where that row actually has a value. A SQL NULL is
    -- absence expressed correctly; asking "is this a placeholder?" about it
    -- invites a yes, which is exactly backwards -- sentinel_used_as_value exists
    -- to find values that STAND IN for NULL. Pruning per row also costs nothing
    -- in cache reuse, since state differs per row regardless.
    questions AS (
        SELECT s.row_id,
               json_group_object(p.qid, q_noul(p.instructions, p.criteria)) AS q
        FROM sem_sample(tbl, rows) s, plan p
        WHERE p.scope = 'row'
           OR coalesce(json_type(s.row_json, sem_path(p.column_name)), 'NULL') <> 'NULL'
        GROUP BY s.row_id
    ),
    asked AS (
        SELECT s.row_id, s.row_json,
               ts_answers(json_object('row', json(s.row_json)), qu.q) AS a
        FROM sem_sample(tbl, rows) s JOIN questions qu USING (row_id)
    )
    SELECT r.row_id,
           p.scope,
           p.column_name,
           p.probe_id,
           noul_of(r.a, p.qid) AS probability,
           CASE WHEN p.scope = 'value'
                THEN json_extract_string(r.row_json, sem_path(p.column_name)) END AS value,
           r.row_json
    FROM asked r, plan p
    WHERE p.scope = 'row'
       OR coalesce(json_type(r.row_json, sem_path(p.column_name)), 'NULL') <> 'NULL'
    ORDER BY probability DESC NULLS LAST, r.row_id;

-- ─────────────────────────────────────────────────────────────────────────────
-- L1, step 4: ask each row finding which fields it is about.
--
-- A row probe answers "is something wrong with this row?" but not what. For
-- every row a probe scored at review_floor or above, one more request asks
-- which field is most responsible, as a choice over the row's columns plus
-- `no_conflict`. The top two fields name the conflict; `no_conflict` on top
-- means the probe backed off when made to point at something.
--
-- One request per candidate row, not per sampled row, and small ones: the
-- state is the row and there is a single question.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE MACRO sem_row_fields(
    tbl, threshold := 0.7, rows := 100, n := 200,
    min_relevance := 0.5, max_per_column := 4, max_row_probes := 5, min_type_confidence := 0.6,
    review_floor := 0.5, review_lift := 0.3, key := NULL
) AS TABLE
    WITH v AS (
        SELECT *, median(probability) OVER (PARTITION BY probe_id) AS probe_median
        FROM sem_values(tbl, rows, n, min_relevance, max_per_column, max_row_probes, min_type_confidence)
        WHERE scope = 'row'
    ),
    -- Which rows get asked depends only on review_floor, never on threshold or
    -- review_lift, so re-slicing a report re-reads cached answers instead of
    -- asking again. A threshold below the floor widens the set and does ask.
    cand AS (
        SELECT *,
               probability >= threshold AS flagged,
               -- Borderline is worth a look when it stands well clear of how that
               -- probe scored the rest of the sample: 0.6 against a typical 0.1
               -- is a signal, 0.6 against a typical 0.5 is the model shrugging.
               probability < threshold AND probability >= review_floor
                   AND probability - probe_median >= review_lift AS to_review
        FROM v
        WHERE probability >= least(threshold, review_floor)
    ),
    plan AS (
        SELECT probe_id, instructions
        FROM sem_plan(tbl, n, min_relevance, max_per_column, max_row_probes, min_type_confidence)
        WHERE scope = 'row'
    ),
    -- The options are the row's columns, each described by its value there.
    opts AS (
        SELECT c.row_id, c.probe_id,
               json_group_object(s.column_name,
                   left(coalesce(json_extract_string(c.row_json, sem_path(s.column_name)), 'NULL'), 120)) AS fields
        FROM cand c, sem_schema(tbl) s
        GROUP BY c.row_id, c.probe_id
    ),
    asked AS (
        SELECT c.*, choice_of(ts_answers(
            json_object('row', json(c.row_json)),
            json_object('primary', q_choice(
                json_object(
                    'question', 'A data-quality check was asked about `row`: "' || p.instructions || '" Which single field in `row` is most responsible for a yes answer?',
                    'note', 'Answer `no_conflict` if, after actually checking the values, nothing in the row satisfies the check.'),
                json_merge_patch(o.fields, '{"no_conflict": "Nothing in the row actually satisfies the check."}')))),
            'primary') AS ch
        FROM cand c JOIN plan p USING (probe_id) JOIN opts o USING (row_id, probe_id)
    ),
    ranked AS (
        SELECT a.row_id, a.probe_id, k AS field, (a.ch.probabilities->>k)::DOUBLE AS p
        FROM asked a, unnest(json_keys(a.ch.probabilities)) AS t(k)
    ),
    top2 AS (
        SELECT row_id, probe_id,
               list(field ORDER BY p DESC, field) FILTER (field <> 'no_conflict')[1:2] AS fields,
               arg_max(field, p) AS top_choice
        FROM ranked
        GROUP BY row_id, probe_id
    )
    SELECT a.row_id,
           json_extract_string(a.row_json, sem_path(sem_key(tbl, key))) AS row_key,
           a.probe_id,
           a.probability, a.flagged, a.to_review,
           t.fields[1] AS field_1,
           t.fields[2] AS field_2,
           t.top_choice = 'no_conflict' AS retracted,
           a.row_json
    FROM asked a JOIN top2 t USING (row_id, probe_id)
    ORDER BY a.probe_id, a.probability DESC, a.row_id;
