#!/usr/bin/env bash
# Compares the tables the migrations create against the ones the remote
# actually exposes.
#
# Why this exists: twice now a migration has been recorded in
# supabase_migrations.schema_migrations while only part of its DDL ever ran.
# The messaging pair went first; then `subscriptions` and `user_settings`, the
# last two CREATE TABLE statements of the initial schema. Both times the
# recorded history said everything was applied, so `db push` had nothing to
# do, and both times the gap surfaced as a broken screen on a phone — the
# second one as a button that did nothing at all.
#
# The CLI cannot answer this: `supabase login` needs a TTY it does not get
# here. The REST API can. A relation PostgREST has never heard of answers
# 404/PGRST205; one that exists but is closed to `anon` answers 401 or 403,
# and one behind RLS answers 200 with an empty array. Only the first means
# missing, so the anon key is enough — no service key, no password, nothing
# privileged.
#
# Usage:  scripts/check_remote_schema.sh            # reads .env
#         SUPABASE_URL=… SUPABASE_ANON_KEY=… scripts/check_remote_schema.sh
#
# Exit 1 if any expected table is missing.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -z "${SUPABASE_URL:-}" ] || [ -z "${SUPABASE_ANON_KEY:-}" ]; then
  [ -f "$ROOT/.env" ] || { echo "no .env and no SUPABASE_URL/SUPABASE_ANON_KEY in the environment"; exit 2; }
  SUPABASE_URL=$(grep '^SUPABASE_URL=' "$ROOT/.env" | cut -d= -f2-)
  SUPABASE_ANON_KEY=$(grep '^SUPABASE_ANON_KEY=' "$ROOT/.env" | cut -d= -f2-)
fi
[ -n "$SUPABASE_URL" ] && [ -n "$SUPABASE_ANON_KEY" ] || { echo "SUPABASE_URL / SUPABASE_ANON_KEY are empty"; exit 2; }

echo "▸ project: $SUPABASE_URL"

# Migrations are read in filename order so a later DROP wins over an earlier
# CREATE. Each surviving table remembers the file that created it, which is
# the only thing worth knowing when one turns up missing.
EXPECTED=$(python3 - "$ROOT/supabase/migrations" <<'PY'
import pathlib, re, sys

created = {}
for f in sorted(pathlib.Path(sys.argv[1]).glob('*.sql')):
    sql = f.read_text()
    for m in re.finditer(
            r'CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?public\.([a-z0-9_]+)',
            sql, re.I):
        created.setdefault(m.group(1).lower(), f.name)
    for m in re.finditer(
            r'DROP\s+TABLE\s+(?:IF\s+EXISTS\s+)?public\.([a-z0-9_]+)',
            sql, re.I):
        created.pop(m.group(1).lower(), None)

for table, origin in sorted(created.items()):
    print(f'{table}\t{origin}')
PY
)

TOTAL=$(printf '%s\n' "$EXPECTED" | grep -c .)
echo "▸ $TOTAL tables expected by the migrations"
echo

MISSING=0
UNKNOWN=0

while IFS=$'\t' read -r table origin; do
  [ -n "$table" ] || continue
  RESP=$(curl -s -w '\n%{http_code}' --max-time 15 \
              -H "apikey: $SUPABASE_ANON_KEY" \
              -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
              "$SUPABASE_URL/rest/v1/$table?select=*&limit=0" || true)
  CODE=$(printf '%s' "$RESP" | tail -1)
  BODY=$(printf '%s' "$RESP" | sed '$d')

  case "$CODE" in
    200|206)  printf '  ok       %s\n' "$table" ;;
    401|403)  printf '  ok       %s  (closed to anon, which still means it exists)\n' "$table" ;;
    404)
      if printf '%s' "$BODY" | grep -q 'PGRST205'; then
        printf '  MISSING  %s  ← created by %s\n' "$table" "$origin"
        MISSING=$((MISSING + 1))
      else
        printf '  ?        %s  (404, but not PGRST205: %s)\n' "$table" "$BODY"
        UNKNOWN=$((UNKNOWN + 1))
      fi
      ;;
    *)        printf '  ?        %s  (HTTP %s)\n' "$table" "$CODE"
              UNKNOWN=$((UNKNOWN + 1)) ;;
  esac
done <<< "$EXPECTED"

echo
if [ "$MISSING" -gt 0 ]; then
  echo "✗ $MISSING table(s) missing on the remote."
  echo
  echo "  The migration that creates each one is named above. It is recorded as"
  echo "  applied, so db push will not go back for it: write a repair migration"
  echo "  re-running its DDL under CREATE TABLE IF NOT EXISTS guards — see"
  echo "  20260829120000_subscriptions_settings_drift_repair.sql — paste it in"
  echo "  the dashboard SQL editor, then record it in schema_migrations by hand."
  exit 1
fi

[ "$UNKNOWN" -gt 0 ] && echo "⚠ $UNKNOWN table(s) could not be classified — check the network, then rerun."
echo "✅ every table the migrations create answers on the remote."

# Known limits, so nobody reads more into a green run than it says:
#   * tables only, no functions. Probing an RPC cannot tell a missing function
#     from an argument-signature mismatch, so a 404 there would mean nothing.
#   * existence only, no columns. A table that landed while a later ALTER did
#     not still reads as ok here.
#   * nothing the other way round: enumerating what the remote has and the
#     migrations do not would need privileges the anon key must never carry.
