-- ─────────────────────────────────────────────────────────────────────────────
-- L2: turn raw judgments into findings.
--
-- No API calls happen here, so thresholds and weights can be re-sliced freely:
-- changing `threshold` re-reads cached judgments rather than re-asking.
--
-- Every finding carries evidence. `examples` holds the actual offending values
-- and `example_rows` the row ids, because a semantic_profile that says "3% of this column
-- looks wrong" without showing you which 3% is not actionable.
-- ─────────────────────────────────────────────────────────────────────────────

-- Column-level findings, from discovery. These need no per-row execution.
CREATE OR REPLACE MACRO sem_column_flags(tbl, n := 200, threshold := 0.7) AS TABLE
    WITH c AS (SELECT * FROM sem_columns(tbl, n))
    SELECT * FROM (
        SELECT 'column' AS scope, column_name, 'name_misdescribes_values' AS probe_id,
               1 - name_matches_values AS probability,
               'column named `' || column_name || '` holds ' || coalesce(semantic_type, 'something else') AS detail
        FROM c
        UNION ALL
        SELECT 'column', column_name, 'sensitive_personal_data', sensitive_personal_data,
               'values carry personal or sensitive data' FROM c
        UNION ALL
        SELECT 'column', column_name, 'format_drift', format_inconsistency / 4.0,
               'values are not formatted consistently' FROM c
        UNION ALL
        SELECT 'column', column_name, 'sentinel_values', has_sentinel_values,
               'placeholder values stand in for missing data' FROM c
        UNION ALL
        SELECT 'column', column_name, 'meaning_not_in_name', is_encoded_code,
               'opaque codes whose meaning the column name does not give' FROM c
        UNION ALL
        SELECT 'column', column_name, 'unit_unrecoverable', 1.0,
               'quantities with no recoverable unit or currency' FROM c
        WHERE unit_or_currency IN ('unstated', 'mixed')
    )
    WHERE probability >= threshold
    ORDER BY probability DESC;

-- Value- and row-level findings, aggregated per probe.
--
-- Row findings are grouped by the field they are about (see sem_row_fields),
-- across probes, so one defect reads as one finding with a count -- "status:
-- 11 rows" -- rather than as eleven, or as the same rows once per probe that
-- noticed them. Two kinds of row judgment are dropped on the way: ones that
-- backed off to `no_conflict` when asked what they were about, and ones whose
-- main field already carries a value finding on that row, which they only
-- restate.
CREATE OR REPLACE MACRO sem_report(
    tbl, threshold := 0.7, rows := 100, n := 200,
    min_relevance := 0.5, max_per_column := 4, max_row_probes := 5, min_type_confidence := 0.6,
    review_floor := 0.5, review_lift := 0.3
) AS TABLE
    WITH v AS (
        SELECT * FROM sem_values(tbl, rows, n, min_relevance, max_per_column, max_row_probes, min_type_confidence)
    ),
    value_findings AS (
        SELECT scope,
               column_name,
               probe_id,
               count(*)                                                   AS rows_checked,
               count(*) FILTER (probability >= threshold)                 AS rows_flagged,
               round(count(*) FILTER (probability >= threshold) / count(*)::DOUBLE, 4) AS flag_rate,
               -- Calibrated uncertainty is a result, not a failure: these are the
               -- cases worth a person's attention rather than an automated verdict.
               count(*) FILTER (probability BETWEEN 0.4 AND 0.6)          AS needs_review,
               round(max(probability), 3)                                 AS max_probability,
               list(DISTINCT value) FILTER (probability >= threshold AND value IS NOT NULL)[1:3] AS examples,
               list(row_id ORDER BY probability DESC) FILTER (probability >= threshold)[1:5]     AS example_rows,
               -- Borderline *value* judgments are not surfaced: on real data they
               -- were mostly a value already flagged by a sibling probe, or noise.
               0::BIGINT                                                  AS rows_to_review,
               NULL::BIGINT[]                                             AS review_rows
        FROM v
        WHERE scope = 'value'
        GROUP BY scope, column_name, probe_id
        HAVING count(*) FILTER (probability >= threshold) > 0
    ),
    flagged_cells AS (
        SELECT DISTINCT row_id, column_name FROM v
        WHERE scope = 'value' AND probability >= threshold
    ),
    rf AS (
        SELECT f.*
        FROM sem_row_fields(tbl, threshold, rows, n, min_relevance, max_per_column, max_row_probes,
                            min_type_confidence, review_floor, review_lift) f
        WHERE (f.flagged OR f.to_review)
          AND NOT f.retracted
          AND NOT EXISTS (SELECT 1 FROM flagged_cells c
                          WHERE c.row_id = f.row_id AND c.column_name = f.field_1)
    ),
    -- Each judgment names two fields, and different rows with the same defect
    -- do not always name the same pair (`status + closed_date` on one row,
    -- `status + notes` on the next). Anchor each judgment on whichever of its
    -- two fields the report as a whole mentions most, which pulls those
    -- together without chaining unrelated pairs. The field named as most
    -- responsible counts double, so ties go to the likelier culprit.
    mentions AS (
        SELECT field, sum(w) AS n
        FROM (SELECT field_1 AS field, 2 AS w FROM rf
              UNION ALL SELECT field_2, 1 FROM rf WHERE field_2 IS NOT NULL)
        GROUP BY field
    ),
    anchored AS (
        SELECT rf.*, m.field AS anchor
        FROM rf JOIN mentions m ON m.field IN (rf.field_1, rf.field_2)
        QUALIFY row_number() OVER (PARTITION BY rf.row_id, rf.probe_id ORDER BY m.n DESC, m.field) = 1
    ),
    -- One entry per row and anchor, however many probes noticed it; the most
    -- confident judgment supplies the evidence.
    per_row AS (
        SELECT row_id, anchor,
               max(probability)                                        AS probability,
               bool_or(flagged)                                        AS flagged,
               list(DISTINCT probe_id ORDER BY probe_id)               AS probes,
               arg_max(anchor || '=' || left(coalesce(json_extract_string(row_json, sem_path(anchor)), 'NULL'), 60)
                       || coalesce('; ' || other || '=' || left(coalesce(json_extract_string(row_json, sem_path(other)), 'NULL'), 60), ''),
                       probability)                                    AS evidence
        FROM (SELECT *, CASE WHEN anchor = field_1 THEN field_2 ELSE field_1 END AS other FROM anchored)
        GROUP BY row_id, anchor
    ),
    sampled AS (
        SELECT count(DISTINCT row_id) AS rows_checked FROM v WHERE scope = 'row'
    ),
    row_findings AS (
        SELECT 'row'                                                      AS scope,
               anchor                                                     AS column_name,
               array_to_string(list_sort(list_distinct(flatten(list(probes)))), ', ') AS probe_id,
               any_value(s.rows_checked)                                  AS rows_checked,
               count(*) FILTER (flagged)                                  AS rows_flagged,
               round(count(*) FILTER (flagged) / any_value(s.rows_checked)::DOUBLE, 4) AS flag_rate,
               NULL::BIGINT                                               AS needs_review,
               round(max(probability), 3)                                 AS max_probability,
               list(evidence ORDER BY probability DESC)[1:3]             AS examples,
               list(row_id ORDER BY probability DESC) FILTER (flagged)[1:5]     AS example_rows,
               count(*) FILTER (NOT flagged)                              AS rows_to_review,
               list(row_id ORDER BY probability DESC) FILTER (NOT flagged)[1:5] AS review_rows
        FROM per_row, sampled s
        GROUP BY anchor
    )
    SELECT * FROM (SELECT * FROM value_findings UNION ALL SELECT * FROM row_findings)
    ORDER BY rows_flagged + rows_to_review DESC, max_probability DESC;

-- Individual flagged rows, for drilling into a finding.
CREATE OR REPLACE MACRO sem_findings(
    tbl, threshold := 0.7, rows := 100, n := 200,
    min_relevance := 0.5, max_per_column := 4, max_row_probes := 5, min_type_confidence := 0.6
) AS TABLE
    SELECT row_id, scope, column_name, probe_id, round(probability, 3) AS probability, value, row_json
    FROM sem_values(tbl, rows, n, min_relevance, max_per_column, max_row_probes, min_type_confidence)
    WHERE probability >= threshold
    ORDER BY probability DESC, row_id;

-- Dry run. Makes no API calls, so this is safe to run before committing spend.
CREATE OR REPLACE MACRO sem_cost(tbl, rows := 100, n := 200, max_row_probes := 5) AS TABLE
    WITH s AS (SELECT count(*) AS n_columns FROM sem_schema(tbl)),
    t AS (SELECT count(*) AS table_rows FROM query_table(tbl)),
    b AS (SELECT avg(length(row_json)) AS avg_row_bytes FROM sem_sample(tbl, least(50, n))),
    e AS (
        SELECT s.n_columns, t.table_rows,
               least(rows, t.table_rows) AS rows_to_probe,
               s.n_columns       AS discovery_requests,
               s.n_columns + 1   AS selection_requests,
               least(rows, t.table_rows) AS execution_requests,
               b.avg_row_bytes
        FROM s, t, b
    )
    SELECT n_columns, table_rows, rows_to_probe,
           discovery_requests, selection_requests, execution_requests,
           discovery_requests + selection_requests + execution_requests AS total_requests,
           -- Step 4 asks only about rows a row probe scored >= 0.5, which is
           -- unknowable before the run, so this is a ceiling, not a count: every
           -- sampled row under every row probe. Runs so far used 3-24% of it.
           execution_requests * max_row_probes AS attribution_requests_max,
           round(avg_row_bytes) AS avg_row_bytes,
           -- Rough, and stated as such: state dominates, ~4 bytes per token.
           round((discovery_requests + selection_requests) * 4000 / 4
                 + execution_requests * (avg_row_bytes + 6000) / 4) AS approx_input_tokens,
           'total_requests excludes step 4, which adds at most attribution_requests_max small requests; '
           || 'cached requests cost nothing; re-running with a different threshold costs nothing' AS note
    FROM e;

-- The one-liner: everything worth looking at, column-level and value-level.
CREATE OR REPLACE MACRO sem_profile(tbl, threshold := 0.7, rows := 100, n := 200) AS TABLE
    SELECT * FROM (
        SELECT scope, column_name, probe_id, detail AS finding,
               NULL::BIGINT AS rows_flagged, NULL::DOUBLE AS flag_rate,
               round(probability, 3) AS max_probability, NULL::VARCHAR[] AS examples,
               NULL::BIGINT[] AS example_rows, NULL::BIGINT AS rows_to_review, NULL::BIGINT[] AS review_rows
        FROM sem_column_flags(tbl, n, threshold)
        UNION ALL
        -- For a row finding, column_name is the pair of fields it is about and
        -- examples shows their values; sem_row_fields has the rows in full.
        SELECT scope, column_name, probe_id,
               CASE WHEN rows_flagged = 0
                    THEN 'below threshold, but these rows stand out from the rest; review_rows lists them' END AS finding,
               rows_flagged, flag_rate, max_probability, examples, example_rows,
               nullif(rows_to_review, 0), nullif(review_rows, [])
        FROM sem_report(tbl, threshold, rows, n)
    )
    ORDER BY coalesce(rows_flagged, 0) + coalesce(rows_to_review, 0) DESC, max_probability DESC;
