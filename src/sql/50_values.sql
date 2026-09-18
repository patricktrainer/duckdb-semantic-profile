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
CREATE OR REPLACE MACRO profile_plan(
    tbl, n := 200, min_relevance := 0.5, max_per_column := 4, max_row_probes := 5,
    min_type_confidence := 0.6
) AS TABLE
    SELECT 'p' || row_number() OVER (ORDER BY scope, column_name NULLS FIRST, probe_id) AS qid,
           scope, column_name, probe_id, instructions, criteria
    FROM profile_probes(tbl, n, min_relevance, max_per_column, max_row_probes, min_type_confidence)
    WHERE selected;

-- Per-value and per-row judgments, in long form: one row per (row, probe).
CREATE OR REPLACE MACRO profile_values(
    tbl, rows := 100, n := 200, min_relevance := 0.5, max_per_column := 4, max_row_probes := 5,
    min_type_confidence := 0.6
) AS TABLE
    WITH plan AS (SELECT * FROM profile_plan(tbl, n, min_relevance, max_per_column, max_row_probes, min_type_confidence)),
    questions AS (
        SELECT json_group_object(qid, q_noul(instructions, criteria)) AS q,
               count(*) AS n_probes
        FROM plan
    ),
    asked AS (
        SELECT s.row_id, s.row_json,
               ts_answers(json_object('row', json(s.row_json)), qu.q) AS a
        FROM profile_sample(tbl, rows) s, questions qu
        -- With nothing selected there is nothing to ask, and an empty question
        -- set is an error rather than a no-op.
        WHERE qu.n_probes > 0
    )
    SELECT r.row_id,
           p.scope,
           p.column_name,
           p.probe_id,
           noul_of(r.a, p.qid) AS probability,
           CASE WHEN p.scope = 'value'
                THEN json_extract_string(r.row_json, profile_path(p.column_name)) END AS value,
           r.row_json
    FROM asked r, plan p
    ORDER BY probability DESC NULLS LAST, r.row_id;
