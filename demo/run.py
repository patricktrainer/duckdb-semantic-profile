"""Live end-to-end demo: profile demo/messy.sql and show what SUMMARIZE misses."""
import sys, duckdb

EXT = sys.argv[1] if len(sys.argv) > 1 else "./build/debug/profiler.duckdb_extension"
ROWS = int(sys.argv[2]) if len(sys.argv) > 2 else 20

con = duckdb.connect(config={"allow_unsigned_extensions": "true"})
con.execute(f"LOAD '{EXT}'")
con.execute(open("demo/messy.sql").read())
con.execute("SELECT profiler_reset_stats()")


def show(title, sql, limit=None):
    print(f"\n{'─' * 78}\n{title}\n{'─' * 78}")
    r = con.sql(sql)
    print(r if limit is None else r.limit(limit))


show("What SUMMARIZE sees: nothing out of place",
     """SELECT column_name, column_type, approx_unique, null_percentage
        FROM (SUMMARIZE shipments)
        WHERE column_name IN ('customer','address','postal_code','weight','shipped_at','notes')""")

show("Dry run: what this will cost before anything is spent",
     f"SELECT n_columns, rows_to_probe, total_requests, approx_input_tokens FROM profile_cost('shipments', rows:={ROWS})")

show("Step 1 — what each column actually holds",
     """SELECT column_name, semantic_type, round(semantic_type_confidence,2) AS conf, role,
               round(name_matches_values,2) AS name_ok, round(sensitive_personal_data,2) AS pii,
               format_inconsistency AS fmt, unit_or_currency
        FROM profile_columns('shipments')""")

show("Step 2 — which checks this table warrants (top 15 of the selected set)",
     """SELECT scope, column_name, probe_id, round(relevance,2) AS relevance
        FROM profile_probes('shipments') WHERE selected ORDER BY relevance DESC""", 15)

show("Step 3 — findings, with evidence",
     f"""SELECT scope, column_name, probe_id, rows_flagged, flag_rate, needs_review,
                max_probability, examples
         FROM profile_report('shipments', rows:={ROWS})""")

show("Cross-column contradictions, per row",
     f"""SELECT row_id, probe_id, probability,
                json_extract_string(row_json,'$.country')     AS country,
                json_extract_string(row_json,'$.postal_code') AS postal_code,
                json_extract_string(row_json,'$.status')      AS status,
                json_extract_string(row_json,'$.shipped_at')  AS shipped_at
         FROM profile_findings('shipments', rows:={ROWS}) WHERE scope = 'row'""")

show("Everything, one call", f"SELECT * FROM profile('shipments', rows:={ROWS})")

print("\nusage:", con.sql("SELECT profiler_stats()").fetchone()[0])
print("\nRe-running now costs nothing: every response above is cached.")
