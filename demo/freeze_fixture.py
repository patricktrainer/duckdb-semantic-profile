"""Freeze the demo's cached responses into a test fixture.

Run after demo/run.sh. The result is a committed JSONL cache that lets the SQL
test suite replay the whole pipeline offline, with no key and no network.
"""
import json, os, shutil, sys

src = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1
                         else "~/.cache/duckdb-profiler/cache.jsonl")
dst = "test/fixtures/shipments_cache.jsonl"
os.makedirs("test/fixtures", exist_ok=True)

seen, kept = set(), []
for line in open(src):
    if not line.strip():
        continue
    e = json.loads(line)
    if e["k"] in seen:          # the log is append-only; keep the last write
        kept = [x for x in kept if x["k"] != e["k"]]
    seen.add(e["k"])
    kept.append(e)

with open(dst, "w") as f:
    for e in kept:
        f.write(json.dumps(e, separators=(",", ":"), ensure_ascii=False) + "\n")

print(f"{len(kept)} unique responses -> {dst} ({os.path.getsize(dst)/1024:.0f} KB)")
