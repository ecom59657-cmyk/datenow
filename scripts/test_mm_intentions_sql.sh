#!/usr/bin/env bash
# Runs supabase/tests/mm_intentions_checks.sql against a throwaway Postgres.
#
# Only the pure function is exercised. `mm_find_match` itself needs PostGIS,
# a populated matchmaking queue and two live heartbeats — it cannot run here,
# which is exactly why the rule was extracted into a function that can.
#
# Nothing here touches the Supabase project or any Postgres you already run:
# it initdb's a fresh cluster in a temp directory, listens on 127.0.0.1:55432
# with no unix socket, and removes the whole thing on exit.
#
# Requires postgresql@17 (brew install postgresql@17). No Docker needed.

set -euo pipefail

PGBIN=${PGBIN:-/opt/homebrew/opt/postgresql@17/bin}
PORT=${PORT:-55432}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="$(mktemp -d)/pgdata"

cleanup() {
  "$PGBIN/pg_ctl" -D "$DATA" stop -m immediate >/dev/null 2>&1 || true
  rm -rf "$(dirname "$DATA")"
}
trap cleanup EXIT

echo "▸ initdb"
"$PGBIN/initdb" -D "$DATA" -U postgres --auth=trust >/dev/null

echo "▸ start on 127.0.0.1:$PORT"
"$PGBIN/pg_ctl" -D "$DATA" \
  -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" \
  -l "$DATA/server.log" start >/dev/null

PSQL="$PGBIN/psql -h 127.0.0.1 -p $PORT -U postgres -v ON_ERROR_STOP=1 -q"
$PSQL -c "CREATE DATABASE dn;" >/dev/null

# Only the pure function is applied: the rest of the migration replaces
# mm_find_match, which needs PostGIS and the full matchmaking schema. The
# function is cut out of the migration file itself rather than duplicated
# here, so this cannot drift from what ships.
echo "▸ extract + apply mm_intentions_compatible"
awk '/^CREATE OR REPLACE FUNCTION public.mm_intentions_compatible/,/^\$fn\$;/' \
  "$ROOT/supabase/migrations/20260819210000_intentions_in_matcher.sql" \
  > "$DATA/fn.sql"
if ! grep -q "mm_intentions_compatible" "$DATA/fn.sql"; then
  echo "✗ could not extract the function from the migration"
  exit 1
fi
$PSQL -d dn -f "$DATA/fn.sql" >/dev/null

echo "▸ checks"
# Not ON_ERROR_STOP: a check that raises is a result, not a reason to hide
# the other fifteen. The runner decides pass/fail from the table below.
set +e
OUT="$("$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d dn \
        -f "$ROOT/supabase/tests/mm_intentions_checks.sql" 2>&1)"
set -e
echo "$OUT" | grep -E "PASS|FAIL|ERREUR|ERROR|erreur" 

if echo "$OUT" | grep -q "FAIL"; then
  echo
  echo "✗ at least one check FAILED"
  exit 1
fi

# A suite that silently ran nothing would otherwise look like a pass.
COUNT=$(echo "$OUT" | grep -c "PASS" || true)
if [ "$COUNT" -lt 19 ]; then
  echo
  echo "✗ expected 19 checks, saw $COUNT — did the script stop early?"
  exit 1
fi

echo
echo "✓ $COUNT/19 checks passed"
