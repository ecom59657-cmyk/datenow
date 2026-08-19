#!/usr/bin/env bash
# Runs supabase/tests/user_background_checks.sql against a throwaway Postgres.
#
# Why this exists: the Dart suite can prove the app never sends a bad value.
# It cannot prove the database would refuse one, nor that the read policy
# hides what the commit message says it hides. Those are claims about
# Postgres, and only Postgres can answer them.
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

# The slice of Supabase the migration leans on. None of it is under test —
# it exists so the migration can run byte-for-byte as it will in production.
echo "▸ supabase stubs"
$PSQL -d dn >/dev/null <<'SQL'
CREATE ROLE authenticated;
CREATE SCHEMA IF NOT EXISTS auth;
CREATE TABLE auth.users (id UUID PRIMARY KEY);
CREATE OR REPLACE FUNCTION auth.uid() RETURNS UUID LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
CREATE TABLE public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE);
CREATE TABLE public.blocked_users (
  user_id UUID NOT NULL, blocked_user_id UUID NOT NULL);
CREATE OR REPLACE FUNCTION public.set_updated_at() RETURNS TRIGGER
  LANGUAGE plpgsql AS $$ BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;
SQL

echo "▸ apply 20260819200000_user_background.sql"
$PSQL -d dn -f "$ROOT/supabase/migrations/20260819200000_user_background.sql" >/dev/null

echo "▸ checks"
# Not ON_ERROR_STOP: a check that raises is a result, not a reason to hide
# the other fifteen. The runner decides pass/fail from the table below.
set +e
OUT="$("$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d dn \
        -f "$ROOT/supabase/tests/user_background_checks.sql" 2>&1)"
set -e
echo "$OUT" | grep -E "PASS|FAIL|ERREUR|ERROR|erreur" 

if echo "$OUT" | grep -q "FAIL"; then
  echo
  echo "✗ at least one check FAILED"
  exit 1
fi

# A suite that silently ran nothing would otherwise look like a pass.
COUNT=$(echo "$OUT" | grep -c "PASS" || true)
if [ "$COUNT" -lt 16 ]; then
  echo
  echo "✗ expected 16 checks, saw $COUNT — did the script stop early?"
  exit 1
fi

echo
echo "✓ $COUNT/16 checks passed"
