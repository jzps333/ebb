-- A 6-digit code is guessable: 10 tries per 10 minutes per account does not
-- stop someone with many free accounts, and a guessed code lets them pair a
-- stranger's watch to their own child. The QR now carries a 20-character
-- random code (~100 bits) that nobody types, so it cannot be guessed.
-- The old 6-digit `code` column stays (not null + check constraint; the
-- tooling blocks dropping them) but nothing reads it any more.

alter table public.pairing_sessions add column qr_code text unique;

create or replace function public.pair_claim_watch(p_code text, p_child_id uuid)
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
  where qr_code = trim(p_code) and expires_at > now()
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

create or replace function public.pair_join_watch(p_code text)
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
  where qr_code = trim(p_code) and expires_at > now();
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
