-- Post-match profile RPC ----------------------------------------------------
--
-- Returns a matched peer's minimal, READ-ONLY profile card for the in-app
-- "fiche profil post-match" screen. The match is enforced SERVER-SIDE on
-- auth.uid(): a direct call with an arbitrary p_user_id returns nothing
-- (raises `no_match`) unless an ACTIVE match exists between the caller and
-- the target. Mirrors the SECURITY DEFINER pattern of claim_match() /
-- mm_find_match().
--
-- Exposes ONLY the fields the product needs:
--   user_id, first_name, age (computed — NEVER birth_date), compatibility_score,
--   main_photo_path (storage path; the bytes are downloaded client-side via the
--   already-matched `profile_photos_select_matched` storage RLS), interests.
-- Never crosses this boundary: birth_date, email, phone, location, timezone,
-- identity/KYC flags, moderation, or any message content.
--
-- Rollback-safe: this migration only CREATEs a function + sets grants. It
-- touches no table, column, RLS policy or data. To roll back:
--   DROP FUNCTION public.get_matched_profile(uuid);

create or replace function public.get_matched_profile(p_user_id uuid)
returns table (
  user_id              uuid,
  first_name           text,
  age                  int,
  compatibility_score  smallint,
  main_photo_path      text,
  interests            text[]
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_self uuid := auth.uid();
begin
  if v_self is null then
    raise exception 'unauthenticated' using errcode = '28000';
  end if;

  if p_user_id = v_self then
    raise exception 'cannot view self via matched profile'
      using errcode = '22023';
  end if;

  -- Gate: an ACTIVE (non-archived) match must exist between the caller and
  -- the target, in either canonical direction. No match → no data.
  if not exists (
    select 1
      from public.matches m
     where m.status <> 'archived'
       and ( (m.user_a_id = v_self      and m.user_b_id = p_user_id)
          or (m.user_b_id = v_self      and m.user_a_id = p_user_id) )
  ) then
    raise exception 'no_match' using errcode = '42501';
  end if;

  return query
  select
    p.id                                       as user_id,
    p.first_name                               as first_name,
    extract(year from age(p.birth_date))::int  as age,
    m.compatibility_score                      as compatibility_score,
    ph.storage_path                            as main_photo_path,
    coalesce(up.interests, '{}')::text[]       as interests
  from public.matches m
  join public.profiles p
    on p.id = p_user_id
  left join public.user_preferences up
    on up.user_id = p_user_id
  -- First moderation-approved photo, primary first then by slot position.
  left join lateral (
    select uph.storage_path
      from public.user_photos uph
     where uph.user_id = p_user_id
       and uph.status  = 'approved'
     order by uph.is_primary desc, uph.position asc
     limit 1
  ) ph on true
  where m.status <> 'archived'
    and ( (m.user_a_id = v_self      and m.user_b_id = p_user_id)
       or (m.user_b_id = v_self      and m.user_a_id = p_user_id) )
  limit 1;
end;
$$;

-- Least privilege: only authenticated end-users may call it (never anon).
revoke all on function public.get_matched_profile(uuid) from public;
revoke all on function public.get_matched_profile(uuid) from anon;
grant execute on function public.get_matched_profile(uuid) to authenticated;
