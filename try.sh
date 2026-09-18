#!/usr/bin/env bash
# Open a DuckDB shell with the semantic_profile loaded and the demo table ready.
#
# The extension is pinned to DuckDB v1.5.5 by the unstable C API, so this uses the
# system duckdb when it is that version, and otherwise falls back to a CLI in
# build/cli (see README).
set -euo pipefail
cd "$(dirname "$0")"

[ -f .env ] && { set -a; . ./.env; set +a; }

NEED=v1.5.5
if command -v duckdb >/dev/null && duckdb --version | grep -q "$NEED"; then
    CLI=duckdb
elif [ -x build/cli/duckdb ]; then
    CLI=build/cli/duckdb
else
    echo "need a DuckDB $NEED CLI: brew upgrade duckdb, or see README"
    duckdb --version 2>/dev/null | sed 's/^/  system duckdb is /'
    exit 1
fi

EXT=build/release/semantic_profile.duckdb_extension
[ -f "$EXT" ] || EXT=build/debug/semantic_profile.duckdb_extension
[ -f "$EXT" ] || { echo "build first: make release"; exit 1; }

# macOS's hardened runtime refuses a relative path in dlopen, so LOAD needs an
# absolute one.
EXT="$PWD/$EXT"

INIT=$(mktemp)
trap 'rm -f "$INIT"' EXIT
cat > "$INIT" <<EOF
LOAD '$EXT';
.read demo/messy.sql
.mode duckbox
EOF

if [ -z "${TYPESAFE_API_KEY:-}" ]; then
    echo "note: no TYPESAFE_API_KEY -- running against the frozen fixture cache (offline)."
    echo "      sem_profile('shipments', rows:=20) replays; anything else will error on a cache miss."
    cat >> "$INIT" <<'EOF'
.output /dev/null
SELECT sem_config('cache_path', 'test/fixtures/shipments_cache.jsonl');
SELECT sem_config('offline', 'true');
.output
EOF
fi

cat <<'EOF'

  Loaded. The `shipments` table has 12 defects planted in it that SUMMARIZE
  cannot see. Try:

    SUMMARIZE shipments;                          -- looks perfectly healthy
    SELECT * FROM sem_profile('shipments', rows:=20); -- what it actually contains

    SELECT * FROM sem_columns('shipments');   -- what each column really is
    SELECT * FROM sem_probes('shipments');    -- checks chosen for this table
    SELECT * FROM sem_cost('shipments');      -- dry run, spends nothing
    SELECT sem_stats();                      -- requests vs cache hits

EOF

exec "$CLI" -unsigned -init "$INIT"
