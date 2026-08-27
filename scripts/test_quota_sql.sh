#!/usr/bin/env bash
# Runs the server-side quota migration against a throwaway Postgres.
#
# Why this exists: the Dart suite can prove the app asks for the right thing.
# It cannot prove Postgres hands out three dates and not five, that a call
# from yesterday stops counting at Paris midnight, that a repackaged client
# cannot mint bonuses past the ceiling, or that the boost lands on the same
# days on both sides of the wire. Those are claims about Postgres.
#
# Nothing here touches the Supabase project or any Postgres you already run:
# it initdb's a fresh cluster in a temp directory, listens on 127.0.0.1:55433
# with no unix socket, and removes the whole thing on exit.
#
# Requires postgresql@17 (brew install postgresql@17). No Docker needed.

set -euo pipefail

PGBIN=${PGBIN:-/opt/homebrew/opt/postgresql@17/bin}
PORT=${PORT:-55433}
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
  -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories='' -c timezone=UTC" \
  -l "$DATA/server.log" start >/dev/null

PSQL="$PGBIN/psql -h 127.0.0.1 -p $PORT -U postgres -v ON_ERROR_STOP=1 -q"
$PSQL -c "CREATE DATABASE dn;" >/dev/null

# The slice of Supabase the migration leans on. None of it is under test — it
# exists so the migration runs byte-for-byte as it will in production. The
# column lists are trimmed to what quota_status() actually reads.
echo "▸ supabase stubs"
$PSQL -d dn >/dev/null <<'SQL'
CREATE ROLE authenticated;
CREATE SCHEMA IF NOT EXISTS auth;
CREATE TABLE auth.users (id UUID PRIMARY KEY);
CREATE OR REPLACE FUNCTION auth.uid() RETURNS UUID LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid $$;

CREATE TABLE public.profiles (
  id     UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  gender TEXT CHECK (gender IN ('female', 'male', 'non_binary')));

CREATE TABLE public.subscriptions (
  user_id      UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  tier         TEXT NOT NULL DEFAULT 'free' CHECK (tier IN ('free','premium')),
  active_until TIMESTAMPTZ);

CREATE TABLE public.calls (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  caller_id  UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  callee_id  UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  status     TEXT NOT NULL DEFAULT 'live');
SQL

echo "▸ apply 20260827100000_quota_server_side.sql"
$PSQL -d dn -f "$ROOT/supabase/migrations/20260827100000_quota_server_side.sql" >/dev/null

echo "▸ structural checks"
set +e
STRUCT="$("$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d dn \
          -f "$ROOT/supabase/tests/quota_checks.sql" 2>&1)"
set -e
echo "$STRUCT" | grep -E "PASS|FAIL|ERROR|ERREUR"

echo
echo "▸ behavioural checks"
set +e
BEHAV="$("$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d dn 2>&1 <<'SQL'
\set QUIET on
\pset tuples_only on
\pset format unaligned

-- Four people. The UUIDs are fixed so a failure is reproducible, and the
-- boost expectations are derived from the hash rather than hard-coded, so
-- these keep passing tomorrow.
CREATE TEMP TABLE ids(label TEXT, id UUID);
INSERT INTO ids VALUES
  ('free_man',    '0000000a-0000-4000-8000-000000000000'),
  ('paid_man',    '0000000a-0000-4000-8000-000000000003'),
  ('lapsed_man',  '0000000a-0000-4000-8000-000000000007'),
  ('woman',       '0000000a-0000-4000-8000-00000000000f');

INSERT INTO auth.users(id) SELECT id FROM ids;
INSERT INTO public.profiles(id, gender)
SELECT id, CASE WHEN label = 'woman' THEN 'female' ELSE 'male' END FROM ids;

INSERT INTO public.subscriptions(user_id, tier, active_until) VALUES
  ('0000000a-0000-4000-8000-000000000003', 'premium', NULL),
  ('0000000a-0000-4000-8000-000000000007', 'premium', now() - interval '1 day');

CREATE TEMP TABLE checks(name TEXT, status TEXT);

CREATE OR REPLACE FUNCTION pg_temp.as_user(u UUID) RETURNS VOID
LANGUAGE sql AS $$ SELECT set_config('request.jwt.claim.sub', u::text, false)::void $$;

CREATE OR REPLACE FUNCTION pg_temp.ck(n TEXT, ok BOOLEAN) RETURNS VOID
LANGUAGE sql AS $$
  INSERT INTO checks VALUES (n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END) $$;

DO $$
DECLARE
  free_man   UUID := '0000000a-0000-4000-8000-000000000000';
  paid_man   UUID := '0000000a-0000-4000-8000-000000000003';
  lapsed_man UUID := '0000000a-0000-4000-8000-000000000007';
  woman      UUID := '0000000a-0000-4000-8000-00000000000f';
  s          JSONB;
  today      DATE := public.quota_day();
  expect     INT;
BEGIN
  -- ── the cap, per tier and per gender ──────────────────────────────
  PERFORM pg_temp.as_user(free_man);
  s := public.quota_status();
  PERFORM pg_temp.ck('a free man gets 3', (s->>'cap')::int = 3);
  PERFORM pg_temp.ck('a free man is not premium', (s->>'is_premium')::bool = false);

  PERFORM pg_temp.as_user(paid_man);
  s := public.quota_status();
  PERFORM pg_temp.ck('a paying man gets 6', (s->>'cap')::int = 6);

  -- A lapsed subscription must not keep paying for itself.
  PERFORM pg_temp.as_user(lapsed_man);
  s := public.quota_status();
  PERFORM pg_temp.ck('an expired premium falls back to 3', (s->>'cap')::int = 3);

  PERFORM pg_temp.as_user(woman);
  s := public.quota_status();
  PERFORM pg_temp.ck('a woman is unlimited', s->>'cap' IS NULL);

  -- ── what counts as a date consumed ────────────────────────────────
  PERFORM pg_temp.as_user(free_man);
  INSERT INTO public.calls(caller_id, callee_id) VALUES (free_man, woman);
  s := public.quota_status();
  PERFORM pg_temp.ck('a date started as caller counts', (s->>'used_today')::int = 1);

  -- caller_id is whichever side polled first, so both must be charged.
  INSERT INTO public.calls(caller_id, callee_id) VALUES (woman, free_man);
  s := public.quota_status();
  PERFORM pg_temp.ck('a date received as callee counts too', (s->>'used_today')::int = 2);

  INSERT INTO public.calls(caller_id, callee_id, started_at)
  VALUES (free_man, woman, now() - interval '2 days');
  s := public.quota_status();
  PERFORM pg_temp.ck('a date from another day does not count',
                     (s->>'used_today')::int = 2);

  -- The boundary itself: one second before Paris midnight is yesterday.
  INSERT INTO public.calls(caller_id, callee_id, started_at)
  VALUES (free_man, woman,
          (today::timestamp AT TIME ZONE 'Europe/Paris') - interval '1 second');
  s := public.quota_status();
  PERFORM pg_temp.ck('the day boundary is Paris midnight',
                     (s->>'used_today')::int = 2);

  -- ── the bonus, and its ceiling ────────────────────────────────────
  s := public.grant_quota_bonus();
  PERFORM pg_temp.ck('a first bonus is granted', (s->>'granted')::bool);
  s := public.quota_status();
  PERFORM pg_temp.ck('the bonus shows in the status', (s->>'bonus_today')::int = 1);

  PERFORM public.grant_quota_bonus();
  PERFORM public.grant_quota_bonus();
  s := public.grant_quota_bonus();
  PERFORM pg_temp.ck('a fourth bonus is refused', (s->>'granted')::bool = false);
  PERFORM pg_temp.ck('and says why', s->>'reason' = 'daily_bonus_limit');

  s := public.quota_status();
  PERFORM pg_temp.ck('the ceiling holds at three', (s->>'bonus_today')::int = 3);

  -- One person's bonuses are not another's.
  PERFORM pg_temp.as_user(paid_man);
  s := public.quota_status();
  PERFORM pg_temp.ck('bonuses do not leak between users',
                     (s->>'bonus_today')::int = 0);

  -- ── the boost ─────────────────────────────────────────────────────
  PERFORM pg_temp.as_user(free_man);
  s := public.quota_status();
  expect := CASE WHEN public.quota_fnv1a(
                   free_man::text || ':' || to_char(today,'YYYY-MM-DD')) % 4 = 0
                 THEN 1 ELSE 0 END;
  PERFORM pg_temp.ck('the boost follows the hash rule',
                     (s->>'boost_today')::int = expect);
  PERFORM pg_temp.ck('the boost is one date or none',
                     (s->>'boost_today')::int IN (0, 1));

  -- Two reads, same answer — the property a die roll would not have.
  PERFORM pg_temp.ck('the boost does not change between reads',
                     (public.quota_status()->>'boost_today')::int
                     = (public.quota_status()->>'boost_today')::int);

  PERFORM pg_temp.as_user(woman);
  s := public.quota_status();
  PERFORM pg_temp.ck('an unlimited user is never boosted',
                     (s->>'boost_today')::int = 0);

  -- ── no identity, no answer ────────────────────────────────────────
  PERFORM set_config('request.jwt.claim.sub', '', false);
  BEGIN
    PERFORM public.quota_status();
    PERFORM pg_temp.ck('an anonymous caller is refused', false);
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.ck('an anonymous caller is refused', SQLERRM = 'not_authenticated');
  END;
END $$;

SELECT name || ' ... ' || status FROM checks;
SQL
)"
set -e
echo "$BEHAV" | grep -E "PASS|FAIL|ERROR|ERREUR"

ALL="$STRUCT
$BEHAV"
if echo "$ALL" | grep -qE "FAIL|ERROR:|ERREUR:"; then
  echo
  echo "✗ at least one check FAILED"
  exit 1
fi

COUNT=$(echo "$ALL" | grep -c "PASS" || true)
EXPECTED=40
if [ "$COUNT" -lt "$EXPECTED" ]; then
  echo
  echo "✗ expected $EXPECTED checks, saw $COUNT — did a script stop early?"
  exit 1
fi

echo
echo "✓ $COUNT/$EXPECTED checks passed"
