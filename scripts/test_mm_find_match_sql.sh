#!/usr/bin/env bash
# Actually RUNS mm_find_match against a throwaway Postgres.
#
# Why this exists: test_background_sql.sh checks every line of the consent
# logic but says of the matcher itself that it "is only checked for creating
# cleanly". Creating cleanly is precisely what
#
#     column reference "peer_id" is ambiguous   (SQLSTATE 42702)
#
# does. plpgsql resolves a name against its variables at RUN time, not at
# CREATE time, so the V2 matcher compiled fine and threw on every single call
# for months — the Edge Function returned a 500, FallbackMatchingDriver
# quietly fell back to V1, and nothing anywhere said the engine was dead.
#
# The missing piece was never PostGIS. It was calling the function once.
# `location` here is an abscissa in km stored as text and ST_Distance is six
# lines of arithmetic: enough to reach the query that mattered.
#
# Requires postgresql@17 (brew install postgresql@17). No Docker needed.

set -euo pipefail

PGBIN=${PGBIN:-/opt/homebrew/opt/postgresql@17/bin}
PORT=${PORT:-55439}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="$(mktemp -d)/pgdata"
WORK="$(mktemp -d)"

cleanup() {
  "$PGBIN/pg_ctl" -D "$DATA" stop -m immediate >/dev/null 2>&1 || true
  rm -rf "$(dirname "$DATA")" "$WORK"
}
trap cleanup EXIT

SELF=11111111-1111-1111-1111-111111111111
PEER=22222222-2222-2222-2222-222222222222

echo "▸ initdb"
"$PGBIN/initdb" -D "$DATA" -U postgres --auth=trust >/dev/null

echo "▸ start on 127.0.0.1:$PORT"
"$PGBIN/pg_ctl" -D "$DATA" \
  -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories='' -c timezone=UTC" \
  -l "$DATA/server.log" start >/dev/null

PSQL="$PGBIN/psql -h 127.0.0.1 -p $PORT -U postgres -v ON_ERROR_STOP=1 -q"
RAW="$PGBIN/psql -h 127.0.0.1 -p $PORT -U postgres -d dn -t -A"
$PSQL -c "CREATE DATABASE dn;" >/dev/null

# The slice of Supabase + PostGIS the matcher leans on. None of it is under
# test — it exists so mm_find_match runs byte-for-byte as it will in
# production. Two compatible people, 1 km apart, both in the queue right now.
echo "▸ supabase + postgis stubs, and two people who should match"
$PSQL -d dn >/dev/null <<SQL
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS UUID LANGUAGE sql STABLE AS \$\$
  SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid \$\$;

CREATE DOMAIN geography AS TEXT;
CREATE FUNCTION ST_Distance(a TEXT, b TEXT) RETURNS DOUBLE PRECISION
  LANGUAGE sql IMMUTABLE AS \$\$
  SELECT abs(a::numeric - b::numeric)::float8 * 1000 \$\$;

CREATE TABLE public.profiles (
  id UUID PRIMARY KEY, gender TEXT, birth_date DATE, location TEXT,
  is_banned BOOLEAN NOT NULL DEFAULT false,
  moderation_status TEXT NOT NULL DEFAULT 'active');
CREATE TABLE public.user_preferences (
  user_id UUID PRIMARY KEY REFERENCES public.profiles(id),
  seeking_genders TEXT[], seeking_age_min INT, seeking_age_max INT,
  max_distance_km INT, intentions TEXT[], interests TEXT[]);
CREATE TABLE public.user_background (
  user_id UUID PRIMARY KEY REFERENCES public.profiles(id),
  origins TEXT[], religion TEXT, drinking TEXT, smoking TEXT, education TEXT,
  match_on_origins BOOLEAN, match_on_religion BOOLEAN);
CREATE TABLE public.matchmaking_queue (
  user_id UUID PRIMARY KEY REFERENCES public.profiles(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL, heartbeat_at TIMESTAMPTZ NOT NULL);
CREATE TABLE public.calls (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  caller_id UUID, callee_id UUID, status TEXT, channel_name TEXT,
  started_at TIMESTAMPTZ, accept_expires_at TIMESTAMPTZ,
  room_expires_at TIMESTAMPTZ);
CREATE TABLE public.blocked_users (user_id UUID, blocked_user_id UUID);
CREATE TABLE public.match_history (
  user_a UUID, user_b UUID, call_id UUID, outcome TEXT, metadata JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now());
CREATE TABLE public.queue_events (user_id UUID, event TEXT, payload JSONB);
CREATE TABLE public.user_presence (
  user_id UUID PRIMARY KEY, status TEXT, updated_at TIMESTAMPTZ);

INSERT INTO public.profiles (id, gender, birth_date, location) VALUES
 ('$SELF','male',  '1995-01-01','0'),
 ('$PEER','female','1996-01-01','1');
INSERT INTO public.user_preferences VALUES
 ('$SELF', ARRAY['female'],18,120,50,ARRAY['serious'],ARRAY['cinema','rando']),
 ('$PEER', ARRAY['male'],  18,120,50,ARRAY['serious'],ARRAY['cinema','cuisine']);
INSERT INTO public.user_background VALUES
 ('$SELF', ARRAY['europe'],'atheist','socially','never','master',true,true),
 ('$PEER', ARRAY['europe'],'atheist','socially','never','master',true,true);
INSERT INTO public.matchmaking_queue (user_id, expires_at, heartbeat_at) VALUES
 ('$SELF', now()+interval '5 min', now()),
 ('$PEER', now()+interval '5 min', now());
INSERT INTO public.user_presence VALUES
 ('$SELF','searching',now()), ('$PEER','searching',now());
SQL

# The scoring helpers come from the real migrations, pulled out by name so a
# future edit to any of them is picked up here without touching this file.
echo "▸ scoring helpers, lifted from the migrations"
python3 - "$ROOT" > "$WORK/helpers.sql" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1]) / 'supabase' / 'migrations'

def extract(fname, name):
    txt = root.joinpath(fname).read_text()
    starts = [m.start() for m in
              re.finditer(rf'CREATE OR REPLACE FUNCTION public\.{name}\b', txt)]
    assert starts, f'{name} not found in {fname}'
    s = starts[-1]                                   # last definition wins
    tag = re.search(r'AS (\$[A-Za-z_]*\$)', txt[s:])
    body = s + tag.end()
    close = txt.index(tag.group(1), body) + len(tag.group(1))
    return txt[s:txt.index(';', close) + 1] + '\n'

sys.stdout.write('\n'.join([
    extract('20260528120000_matching_engine_v2.sql',   'mm_jaccard'),
    extract('20260528120000_matching_engine_v2.sql',   'mm_history_penalty'),
    extract('20260819210000_intentions_in_matcher.sql','mm_intentions_compatible'),
    extract('20260827120000_background_in_matcher.sql','mm_ordinal_closeness'),
    extract('20260827120000_background_in_matcher.sql','mm_lifestyle_score'),
    extract('20260827120000_background_in_matcher.sql','mm_affinity_score'),
]))
PY
$PSQL -d dn -f "$WORK/helpers.sql" >/dev/null

echo "▸ apply 20260827120000_background_in_matcher.sql (mm_find_match)"
sed -n '174,417p' "$ROOT/supabase/migrations/20260827120000_background_in_matcher.sql" \
  > "$WORK/matcher.sql"
$PSQL -d dn -f "$WORK/matcher.sql" >/dev/null

echo "▸ apply 20260829130000_mm_find_match_peer_id_ambiguity.sql"
$PSQL -d dn -f "$ROOT/supabase/migrations/20260829130000_mm_find_match_peer_id_ambiguity.sql" >/dev/null

echo
echo "▸ the one call that matters"
set +e
OUT="$($RAW -c "SELECT set_config('request.jwt.claim.sub','$SELF',false);
                SELECT matched, peer_id, score
                  FROM public.mm_find_match();" 2>&1 | tail -1)"
RC=$?
set -e
echo "  → $OUT"

fail() { echo "FAIL: $1"; exit 1; }
[ $RC -eq 0 ]                      || fail "mm_find_match raised: $OUT"
case "$OUT" in
  *ambig*)  fail "the 42702 ambiguity is back" ;;
  t\|$PEER\|*) : ;;
  *)        fail "expected a match with $PEER, got: $OUT" ;;
esac
SCORE="${OUT##*|}"
[ "$SCORE" -ge 40 ] 2>/dev/null    || fail "score $SCORE below the default floor of 40"
echo "PASS matched=true peer=$PEER score=$SCORE"

echo
echo "▸ side effects"
CHECKS="$($RAW <<'SQL'
SELECT CASE WHEN count(*) = 1 AND max(status) = 'waiting'
            THEN 'PASS' ELSE 'FAIL' END || ' one waiting call' FROM public.calls;
SELECT CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END
       || ' both peers pulled from the queue' FROM public.matchmaking_queue;
SELECT CASE WHEN count(*) = 1 AND max(outcome) = 'proposed'
            THEN 'PASS' ELSE 'FAIL' END || ' match_history row' FROM public.match_history;
SELECT CASE WHEN count(*) = 2 THEN 'PASS' ELSE 'FAIL' END
       || ' two queue_events' FROM public.queue_events;
SELECT CASE WHEN count(*) = 2 THEN 'PASS' ELSE 'FAIL' END
       || ' both presences in_call' FROM public.user_presence WHERE status = 'in_call';
SQL
)"
echo "$CHECKS" | sed 's/^/  /'
echo "$CHECKS" | grep -q FAIL && { echo; echo "FAIL"; exit 1; }

echo
echo "✅ all green"
