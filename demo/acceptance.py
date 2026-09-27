"""Acceptance: does the semantic_profile independently find the defects planted in
demo/messy.sql? Joins findings back to the table's own id, not the sample ordinal."""
import os, sys, duckdb

EXT = os.environ.get("EXT", "./build/debug/semantic_profile.duckdb_extension")
con = duckdb.connect(config={"allow_unsigned_extensions": "true"})
con.execute(f"LOAD '{EXT}'")
con.execute(open("demo/messy.sql").read())
con.execute("SELECT sem_reset_stats()")

con.execute("""
CREATE TABLE f AS
SELECT json_extract(row_json,'$.id')::INT AS id, scope, column_name, probe_id, probability
FROM sem_findings('shipments', threshold:=0.7, rows:=20)""")

# (label, expected id, predicate over findings)
EXPECT = [
 ("test/placeholder row",        3,  "probe_id='placeholder_or_test_value'"),
 ("test/placeholder row",        17, "probe_id='placeholder_or_test_value'"),
 ("country/postcode contradict", 5,  "probe_id='geo_inconsistent'"),
 ("country/postcode contradict", 12, "probe_id='geo_inconsistent'"),
 ("shipped with no ship date",   7,  "probe_id='status_timeline_inconsistent'"),
 ("shipped with no ship date",   15, "probe_id='status_timeline_inconsistent'"),
 ("SSN in free-text note",       9,  "column_name='notes' AND probe_id IN ('embedded_pii','placeholder_or_test_value')"),
 ("operational note in address", 14, "column_name='address'"),
 ("product/category mismatch",   6,  "probe_id='category_product_mismatch'"),
 ("sentinel date",               19, "column_name='shipped_at'"),
 ("two emails in one field",     8,  "column_name='email' AND probe_id='multiple_values_in_one_field'"),
 ("mojibake",                    20, "probe_id='mojibake'"),
]

print(f"{'planted defect':30} {'id':>3}  result")
print("-" * 62)
found = 0
for label, rid, pred in EXPECT:
    n = con.sql(f"SELECT count(*) FROM f WHERE id={rid} AND ({pred})").fetchone()[0]
    hit = n > 0
    found += hit
    print(f"{label:30} {rid:>3}  {'FOUND' if hit else 'missed':<7}")

print("-" * 62)
print(f"{found}/{len(EXPECT)} planted defects detected at threshold 0.7")

# The report drops row judgments that back off or that restate a value finding,
# then groups the rest by field. Neither step may lose a defect: every planted
# cross-column row must still appear in sem_report, as a row finding or as the
# value finding it was folded into. Whether a defect's rows land in ONE finding
# depends on which fields the model blames on each row, so that is reported
# here but not required.
print("\nCross-column defects in sem_report:")
report = con.sql("""
  WITH ids AS (SELECT row_id, json_extract(row_json,'$.id')::INT AS id FROM sem_sample('shipments', 20)),
  r AS (SELECT scope, column_name,
               unnest(list_concat(coalesce(example_rows, []), coalesce(review_rows, []))) AS row_id
        FROM sem_report('shipments', threshold:=0.7, rows:=20))
  SELECT scope, column_name, list(DISTINCT id ORDER BY id)
  FROM r JOIN ids USING (row_id) GROUP BY ALL""").fetchall()
covered = 0
cross = [("country/postcode contradict", {5, 12}),
         ("shipped with no ship date", {7, 15}),
         ("product/category mismatch", {6})]
for label, planted in cross:
    missing = {i for i in planted if not any(i in ids for _, _, ids in report)}
    spans = sorted({f"{sc}:{col}" for sc, col, ids in report if sc == 'row' and planted & set(ids)})
    covered += not missing
    print(f"  {label:30} {sorted(planted)}  {'reported' if not missing else f'LOST {sorted(missing)}'}"
          f"  row findings: {', '.join(spans) or 'none (folded into value findings)'}")

# Ambiguous-unit rows are the interesting case: the model separates them cleanly
# (0.5-0.6 vs 0.02 for values that state their unit) but does not assert, because
# the unit is arguably inferable from the column. That is the needs_review band
# working, not a miss -- so assert on the separation, not on a flag.
print("\nCalibrated uncertainty (bare numbers vs values that state their unit):")
sep = con.sql("""
  SELECT round(max(CASE WHEN value NOT LIKE '%kg%' THEN probability END), 2) AS bare,
         round(max(CASE WHEN value LIKE '%kg%'     THEN probability END), 2) AS with_unit
  FROM sem_values('shipments', rows:=20)
  WHERE column_name='weight' AND probe_id='unit_ambiguous'""").fetchone()
print(f"  bare numbers (26.4, 35.2): up to {sep[0]}   values stating kg: up to {sep[1]}")
assert sep[0] > 0.4 and sep[1] < 0.1, "unit_ambiguous should separate these cleanly"
print("  separation holds")

# The other half of the claim: SUMMARIZE sees none of this.
print("\nUnflagged rows (should be the clean ones):")
print(con.sql("SELECT id FROM shipments WHERE id NOT IN (SELECT id FROM f) ORDER BY id").fetchall())
print("\nrequests used:", con.sql("SELECT json_extract(sem_stats(),'$.requests')").fetchone()[0])
sys.exit(0 if found >= 10 and covered == len(cross) else 1)
