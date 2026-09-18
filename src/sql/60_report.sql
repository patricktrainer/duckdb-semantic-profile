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
CREATE OR REPLACE MACRO sem_report(
    tbl, threshold := 0.7, rows := 100, n := 200,
    min_relevance := 0.5, max_per_column := 4, max_row_probes := 5, min_type_confidence := 0.6
) AS TABLE
    WITH v AS (
        SELECT * FROM sem_values(tbl, rows, n, min_relevance, max_per_column, max_row_probes, min_type_confidence)
    )
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
           list(row_id ORDER BY probability DESC) FILTER (probability >= threshold)[1:5]     AS example_rows
    FROM v
    GROUP BY scope, column_name, probe_id
    HAVING count(*) FILTER (probability >= threshold) > 0
    ORDER BY rows_flagged DESC, max_probability DESC;

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
CREATE OR REPLACE MACRO sem_cost(tbl, rows := 100, n := 200) AS TABLE
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
           round(avg_row_bytes) AS avg_row_bytes,
           -- Rough, and stated as such: state dominates, ~4 bytes per token.
           round((discovery_requests + selection_requests) * 4000 / 4
                 + execution_requests * (avg_row_bytes + 6000) / 4) AS approx_input_tokens,
           'cached requests cost nothing; re-running with a different threshold costs nothing' AS note
    FROM e;

-- The one-liner: everything worth looking at, column-level and value-level.
CREATE OR REPLACE MACRO sem_profile(tbl, threshold := 0.7, rows := 100, n := 200) AS TABLE
    SELECT * FROM (
        SELECT scope, column_name, probe_id, detail AS finding,
               NULL::BIGINT AS rows_flagged, NULL::DOUBLE AS flag_rate,
               round(probability, 3) AS max_probability, NULL::VARCHAR[] AS examples
        FROM sem_column_flags(tbl, n, threshold)
        UNION ALL
        SELECT scope, column_name, probe_id, NULL AS finding,
               rows_flagged, flag_rate, max_probability, examples
        FROM sem_report(tbl, threshold, rows, n)
    )
    ORDER BY coalesce(rows_flagged, 0) DESC, max_probability DESC;
