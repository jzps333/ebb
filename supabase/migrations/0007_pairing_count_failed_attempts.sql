-- 0006's functions raised an exception on a wrong code, which rolled back the
-- whole call, including the pairing_attempts row. So failed guesses were never
-- counted. Code errors now return {"ok": false, "error": "..."} instead, so the
-- attempt row commits. Changing the return type (text -> jsonb) needs a drop,
-- which the Supabase tooling blocks, so the fixed versions get new names and
-- the old ones lose their EXECUTE grant (nothing called them yet).
--   success: {"ok": true, "nickname": "Sam"}

revoke all on function public.claim_watch(text, uuid) from public, anon, authenticated;
revoke all on function public.join_watch(text)        from public, anon, authenticated;

create function public.pair_claim_watch(p_code text, p_child_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := (select auth.uid());
  v_session  public.pairing_sessions;
  v_nickname text;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'error', 'not signed in'); end if;
  if (select count(*) from private.pairing_attempts
      where user_id = v_uid and at > now() - interval '10 minutes') >= 10 then
    return jsonb_build_object('ok', false, 'error', 'too many tries, wait a few minutes');
  end if;
  insert into private.pairing_attempts (user_id) values (v_uid);

  select nickname into v_nickname from public.children
  where id = p_child_id and owner_id = v_uid;
  if v_nickname is null then return jsonb_build_object('ok', false, 'error', 'not your child'); end if;

  select * into v_session from public.pairing_sessions
  where code = trim(p_code) and expires_at > now()
  order by created_at desc limit 1
  for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'code not found or expired'); end if;

  if v_session.child_id is not null and v_session.child_id <> p_child_id then
    return jsonb_build_object('ok', false, 'error', 'this watch is already paired');
  end if;

  update public.pairing_sessions
  set child_id = p_child_id, claimed_by = v_uid, claimed_at = coalesce(claimed_at, now())
  where id = v_session.id;
  return jsonb_build_object('ok', true, 'nickname', v_nickname);
end;
$$;

create function public.pair_join_watch(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := (select auth.uid());
  v_session  public.pairing_sessions;
  v_nickname text;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'error', 'not signed in'); end if;
  if not exists (select 1 from public.profiles where id = v_uid and role = 'teacher') then
    return jsonb_build_object('ok', false, 'error', 'only teacher accounts can join a watch');
  end if;
  if (select count(*) from private.pairing_attempts
      where user_id = v_uid and at > now() - interval '10 minutes') >= 10 then
    return jsonb_build_object('ok', false, 'error', 'too many tries, wait a few minutes');
  end if;
  insert into private.pairing_attempts (user_id) values (v_uid);

  select * into v_session from public.pairing_sessions
  where code = trim(p_code) and expires_at > now()
  order by created_at desc limit 1;
  if not found then return jsonb_build_object('ok', false, 'error', 'code not found or expired'); end if;
  if v_session.child_id is null then
    return jsonb_build_object('ok', false, 'error', 'the parent has not paired this watch yet');
  end if;

  insert into public.child_members (child_id, user_id, role)
  values (v_session.child_id, v_uid, 'teacher')
  on conflict do nothing;

  select nickname into v_nickname from public.children where id = v_session.child_id;
  return jsonb_build_object('ok', true, 'nickname', v_nickname);
end;
$$;

revoke all on function public.pair_claim_watch(text, uuid) from public, anon;
revoke all on function public.pair_join_watch(text)        from public, anon;
grant execute on function public.pair_claim_watch(text, uuid) to authenticated;
grant execute on function public.pair_join_watch(text)        to authenticated;

-- No longer used by anything.
revoke all on function private.check_pairing_rate_limit() from public, authenticated;
