#!/usr/bin/env bash
# End-to-end live demo: profile a table whose defects SUMMARIZE cannot see.
set -euo pipefail
cd "$(dirname "$0")/.."

# Convenience for local runs; .env is gitignored.
if [ -f .env ]; then set -a; . ./.env; set +a; fi

: "${TYPESAFE_API_KEY:?set TYPESAFE_API_KEY in the environment or in a .env file}"
EXT=${EXT:-./build/debug/semantic_profile.duckdb_extension}
[ -f "$EXT" ] || { echo "build first: make debug"; exit 1; }

./configure/venv/bin/python3 demo/run.py "$EXT" "${1:-20}"
