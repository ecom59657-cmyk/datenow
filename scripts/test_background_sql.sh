#!/usr/bin/env bash
# Checks the background matching axes against a throwaway Postgres.
#
# The Dart half is pinned by test/background_matching_test.dart. This is the
# other half: the rule that makes weighing origins and religion lawful has to
# hold in Postgres too, because the SQL matcher is what actually decides who
# meets whom — the Dart score only decides what number is printed.
#
# mm_find_match itself needs PostGIS and the whole matching schema, which a
# brew Postgres does not have. What is exercised here is every line of the
# consent logic; the matcher is only checked for creating cleanly.
#
# Requires postgresql@17. No Docker needed.

set -euo pipefail

PGBIN=${PGBIN:-/opt/homebrew/opt/postgresql@17/bin}
PORT=${PORT:-55434}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="$(mktemp -d)/pgdata"

cleanup() {
  "$PGBIN/pg_ctl" -D "$DATA" stop -m immediate >/dev/null 2>&1 || true
  rm -rf "$(dirname "$DATA")"
}
trap cleanup EXIT

echo "▸ initdb"; "$PGBIN/initdb" -D "$DATA" -U postgres --auth=trust >/dev/null
echo "▸ start on 127.0.0.1:$PORT"
"$PGBIN/pg_ctl" -D "$DATA" \
  -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" \
  -l "$DATA/server.log" start >/dev/null

PSQL="$PGBIN/psql -h 127.0.0.1 -p $PORT -U postgres -v ON_ERROR_STOP=1 -q"
$PSQL -c "CREATE DATABASE dn;" >/dev/null

echo "▸ stubs"
$PSQL -d dn >/dev/null <<'SQL'
CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.uid() RETURNS UUID LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
CREATE TABLE public.profiles (id UUID PRIMARY KEY);
CREATE TABLE public.user_background (
  user_id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  origins TEXT[] NOT NULL DEFAULT '{}', religion TEXT,
  drinking TEXT, smoking TEXT, education TEXT);
-- mm_jaccard is a dependency of the affinity function.
CREATE OR REPLACE FUNCTION public.mm_jaccard(a TEXT[], b TEXT[])
RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN cardinality(a) = 0 OR cardinality(b) = 0 THEN 0
    ELSE cardinality(ARRAY(SELECT unnest(a) INTERSECT SELECT unnest(b)))::numeric
       / cardinality(ARRAY(SELECT unnest(a) UNION SELECT unnest(b))) END $$;
SQL

echo "▸ apply 20260827120000_background_in_matcher.sql (functions only)"
# The matcher recreation needs PostGIS and the queue schema; the consent
# logic does not. Split at the marker the migration writes for that reason.
awk '/── Le matcher, avec les deux nouveaux axes/{exit} {print}' \
  "$ROOT/supabase/migrations/20260827120000_background_in_matcher.sql" \
  > "$DATA/functions.sql"
$PSQL -d dn -f "$DATA/functions.sql" >/dev/null

echo "▸ checks"
# Written to a file rather than piped inside $(...): the SQL is full of
# single quotes, and bash still scans quoting when it looks for the closing
# paren of a command substitution.
cat > "$DATA/checks.sql" <<'SQL'
CREATE TEMP TABLE checks(name TEXT, status TEXT);
CREATE OR REPLACE FUNCTION pg_temp.ck(n TEXT, ok BOOLEAN) RETURNS VOID
LANGUAGE sql AS $fn$ INSERT INTO checks VALUES (n, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END) $fn$;

DO $blk$
BEGIN
  -- consentement : les deux cotes, toujours
  PERFORM pg_temp.ck('answered but not consented, no axis',
    public.mm_affinity_score('{}','{}', 'catholic','catholic',
                             false,false, false,false) IS NULL);
  PERFORM pg_temp.ck('one side consenting is not enough',
    public.mm_affinity_score('{}','{}', 'muslim','muslim',
                             false,false, true,false) IS NULL);
  PERFORM pg_temp.ck('both consenting and agreeing scores full',
    public.mm_affinity_score('{}','{}', 'jewish','jewish',
                             false,false, true,true) = 1);
  PERFORM pg_temp.ck('both consenting and differing scores zero',
    public.mm_affinity_score('{}','{}', 'hindu','atheist',
                             false,false, true,true) = 0);
  PERFORM pg_temp.ck('consent without an answer weighs nothing',
    public.mm_affinity_score('{}','{}', NULL,NULL,
                             true,true, true,true) IS NULL);
  PERFORM pg_temp.ck('origins are overlap, not identity',
    public.mm_affinity_score(ARRAY['europe','caribbean'], ARRAY['europe'],
                             NULL,NULL, true,true, false,false)
    BETWEEN 0.4 AND 0.6);
  PERFORM pg_temp.ck('a shared origin beats none',
    public.mm_affinity_score(ARRAY['europe'], ARRAY['europe'],
                             NULL,NULL, true,true, false,false)
    > public.mm_affinity_score(ARRAY['europe'], ARRAY['eastAsia'],
                               NULL,NULL, true,true, false,false));

  -- mode de vie : pas d opt-in separe
  PERFORM pg_temp.ck('drinking alone is enough',
    public.mm_lifestyle_score('never','never', NULL,NULL, NULL,NULL) = 1);
  PERFORM pg_temp.ck('nothing shared, no axis',
    public.mm_lifestyle_score(NULL,'never', 'often',NULL, NULL,NULL) IS NULL);
  PERFORM pg_temp.ck('a field only one side answered is skipped',
    public.mm_lifestyle_score('never','never', NULL,'often', NULL,NULL) = 1);
  PERFORM pg_temp.ck('opposite ends score below neighbours',
    public.mm_lifestyle_score('never','often', NULL,NULL, NULL,NULL)
    < public.mm_lifestyle_score('never','socially', NULL,NULL, NULL,NULL));
  PERFORM pg_temp.ck('other education matches itself only',
    public.mm_lifestyle_score(NULL,NULL, NULL,NULL, 'other','other') = 1
    AND public.mm_lifestyle_score(NULL,NULL, NULL,NULL, 'other','master') = 0);
  PERFORM pg_temp.ck('neighbouring degrees beat distant ones',
    public.mm_lifestyle_score(NULL,NULL, NULL,NULL, 'bachelor','master')
    > public.mm_lifestyle_score(NULL,NULL, NULL,NULL, 'highSchool','doctorate'));
  PERFORM pg_temp.ck('several fields are averaged, not summed',
    public.mm_lifestyle_score('never','never', 'never','regularly', NULL,NULL)
    BETWEEN 0.4 AND 0.6);
  PERFORM pg_temp.ck('scores stay inside 0..1',
    public.mm_lifestyle_score('often','never','regularly','never','other','master')
      BETWEEN 0 AND 1);

  -- les colonnes de consentement
  PERFORM pg_temp.ck('consent columns default to false',
    (SELECT count(*) FROM information_schema.columns
      WHERE table_name='user_background'
        AND column_name IN ('match_on_origins','match_on_religion')
        AND column_default LIKE '%false%') = 2);
END $blk$;

SELECT name || ' ... ' || status FROM checks;
SQL

set +e
OUT="$("$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d dn \
        --pset=tuples_only --pset=format=unaligned -f "$DATA/checks.sql" 2>&1)"
set -e
echo "$OUT" | grep -E "PASS|FAIL|ERROR|ERREUR"

if echo "$OUT" | grep -qE "FAIL|ERROR:|ERREUR:"; then
  echo; echo "✗ at least one check FAILED"; exit 1
fi
COUNT=$(echo "$OUT" | grep -c "PASS" || true)
EXPECTED=16
if [ "$COUNT" -lt "$EXPECTED" ]; then
  echo; echo "✗ expected $EXPECTED checks, saw $COUNT"; exit 1
fi
echo; echo "✓ $COUNT/$EXPECTED checks passed"
