-- QR pairing. An unpaired watch asks device-api for a 6-digit code and shows
-- it as a QR. In the iPhone app the parent scans it and picks a child
-- (claim_watch); teachers scan the same code to link themselves to that child
-- (join_watch). The watch then fetches its device token once, with a secret
-- only it holds. Codes work for 15 minutes.

create table public.pairing_sessions (
  id               uuid primary key default gen_random_uuid(),
  code             text not null check (code ~ '^[0-9]{6}$'),
  secret_hash      text not null unique,          -- SHA-256 of the watch's pairing secret
  hardware_id      text,
  child_id         uuid references public.children (id) on delete cascade,
  claimed_by       uuid references public.profiles (id) on delete set null,
  claimed_at       timestamptz,
  device_id        uuid references public.devices (id) on delete set null,
  token_issued_at  timestamptz,
  created_at       timestamptz not null default now(),
  expires_at       timestamptz not null default now() + interval '15 minutes'
);

create index pairing_sessions_code_idx       on public.pairing_sessions (code, expires_at);
create index pairing_sessions_child_id_idx   on public.pairing_sessions (child_id);
create index pairing_sessions_claimed_by_idx on public.pairing_sessions (claimed_by);
create index pairing_sessions_device_id_idx  on public.pairing_sessions (device_id);
create index devices_hardware_id_idx         on public.devices (hardware_id);

-- Only device-api (service role) and the functions below touch it.
alter table public.pairing_sessions enable row level security;
revoke all on public.pairing_sessions from anon, authenticated;

-- Failed and successful code entries, for rate limiting guesses.
create table private.pairing_attempts (
  user_id  uuid not null,
  at       timestamptz not null default now()
);
create index pairing_attempts_user_at_idx on private.pairing_attempts (user_id, at);

-- 10 code entries per 10 minutes per account: a 6-digit code cannot be guessed.
create or replace function private.check_pairing_rate_limit()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select count(*) from private.pairing_attempts
      where user_id = (select auth.uid()) and at > now() - interval '10 minutes') >= 10 then
    raise exception 'too many tries, wait a few minutes';
  end if;
  insert into private.pairing_attempts (user_id) values ((select auth.uid()));
end;
$$;
revoke all on function private.check_pairing_rate_limit() from public;

-- Parent scans the watch: link it to one of their children. Returns the nickname.
create or replace function public.claim_watch(p_code text, p_child_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := (select auth.uid());
  v_session  public.pairing_sessions;
  v_nickname text;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  perform private.check_pairing_rate_limit();

  select nickname into v_nickname from public.children
  where id = p_child_id and owner_id = v_uid;
  if v_nickname is null then raise exception 'not your child'; end if;

  select * into v_session from public.pairing_sessions
  where code = trim(p_code) and expires_at > now()
  order by created_at desc limit 1
  for update;
  if not found then raise exception 'code not found or expired'; end if;

  if v_session.child_id is not null then
    if v_session.child_id = p_child_id then return v_nickname; end if;  -- scanned twice
    raise exception 'this watch is already paired';
  end if;

  update public.pairing_sessions
  set child_id = p_child_id, claimed_by = v_uid, claimed_at = now()
  where id = v_session.id;
  return v_nickname;
end;
$$;

-- Teacher scans the watch after the parent has paired it: link the teacher
-- to that child. Returns the nickname.
create or replace function public.join_watch(p_code text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := (select auth.uid());
  v_session  public.pairing_sessions;
  v_nickname text;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if not exists (select 1 from public.profiles where id = v_uid and role = 'teacher') then
    raise exception 'only teacher accounts can join a watch';
  end if;
  perform private.check_pairing_rate_limit();

  select * into v_session from public.pairing_sessions
  where code = trim(p_code) and expires_at > now()
  order by created_at desc limit 1;
  if not found then raise exception 'code not found or expired'; end if;
  if v_session.child_id is null then
    raise exception 'the parent has not paired this watch yet';
  end if;

  insert into public.child_members (child_id, user_id, role)
  values (v_session.child_id, v_uid, 'teacher')
  on conflict do nothing;

  select nickname into v_nickname from public.children where id = v_session.child_id;
  return v_nickname;
end;
$$;

revoke all on function public.claim_watch(text, uuid) from public, anon;
revoke all on function public.join_watch(text)        from public, anon;
grant execute on function public.claim_watch(text, uuid) to authenticated;
grant execute on function public.join_watch(text)        to authenticated;
