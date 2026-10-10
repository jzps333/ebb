-- Ebb: initial schema.
-- Eight tables, all with Row Level Security. A teacher or parent can only reach
-- students they own or are linked to. devices and events are written only by
-- the device-api Edge Function (service role, bypasses RLS).

create schema if not exists private;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

-- One row per teacher or parent, created by a trigger on sign-up.
create table public.profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  display_name  text,
  role          text not null check (role in ('parent', 'teacher')),
  created_at    timestamptz not null default now()
);

-- A student. No account, no full name or birthday: nickname + age band only.
create table public.children (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  nickname    text not null check (char_length(nickname) between 1 and 40),
  age_band    text not null check (age_band in ('4-5', '6-8', '9-11', '12-14', '15-18')),
  consent_at  timestamptz not null,
  created_at  timestamptz not null default now()
);

-- Links a teacher to one student. Added by the parent via add_teacher_by_email().
create table public.child_members (
  child_id    uuid not null references public.children (id) on delete cascade,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  role        text not null default 'teacher' check (role = 'teacher'),
  created_at  timestamptz not null default now(),
  primary key (child_id, user_id)
);

create table public.assessments (
  id          uuid primary key default gen_random_uuid(),
  child_id    uuid not null references public.children (id) on delete cascade,
  answers     jsonb not null,
  created_by  uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now()
);

-- AI-made calm profile. Saved as draft; the parent approves before the watch gets it.
create table public.calm_profiles (
  id           uuid primary key default gen_random_uuid(),
  child_id     uuid not null references public.children (id) on delete cascade,
  version      integer not null check (version > 0),
  profile      jsonb not null,
  status       text not null default 'draft' check (status in ('draft', 'approved')),
  model        text,
  created_at   timestamptz not null default now(),
  approved_at  timestamptz,
  unique (child_id, version)
);

-- A watch. Only the SHA-256 hex of its token is stored.
create table public.devices (
  id                uuid primary key default gen_random_uuid(),
  child_id          uuid references public.children (id) on delete set null,
  hardware_id       text,
  token_hash        text not null unique,
  last_seen_at      timestamptz,
  battery_pct       integer check (battery_pct between 0 and 100),
  firmware_version  text,
  calm_active       boolean not null default false,
  created_at        timestamptz not null default now()
);

-- Start/stop requests from the website. The watch picks them up on its next poll.
create table public.commands (
  id            uuid primary key default gen_random_uuid(),
  device_id     uuid not null references public.devices (id) on delete cascade,
  child_id      uuid not null references public.children (id) on delete cascade,
  type          text not null check (type in ('start_calm', 'stop_calm')),
  created_by    uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  created_at    timestamptz not null default now(),
  delivered_at  timestamptz,
  done_at       timestamptz
);

-- Calm sessions reported by the watch. Start report inserts the row (ended_at
-- null); the end report has the same started_at and fills ended_at.
create table public.events (
  id            uuid primary key default gen_random_uuid(),
  device_id     uuid not null references public.devices (id) on delete cascade,
  child_id      uuid references public.children (id) on delete cascade,
  trigger       text not null check (trigger in ('teacher', 'motion', 'noise', 'child_tap')),
  command_id    uuid references public.commands (id) on delete set null,
  started_by    uuid references public.profiles (id) on delete set null,
  started_at    timestamptz not null,
  ended_at      timestamptz,
  noise_db      real,
  motion_score  real,
  helped        boolean,
  created_at    timestamptz not null default now(),
  unique (device_id, started_at)
);

-- ---------------------------------------------------------------------------
-- Indexes on every column a policy or the watch's poll filters on
-- ---------------------------------------------------------------------------
create index children_owner_id_idx        on public.children (owner_id);
create index child_members_user_id_idx    on public.child_members (user_id);
create index assessments_child_id_idx     on public.assessments (child_id);
create index calm_profiles_child_id_idx   on public.calm_profiles (child_id);
create index devices_child_id_idx         on public.devices (child_id);
create index commands_child_id_idx        on public.commands (child_id);
create index commands_pending_idx         on public.commands (device_id, created_at) where delivered_at is null;
create index events_child_id_idx          on public.events (child_id, started_at desc);
create index events_device_id_idx         on public.events (device_id);

-- ---------------------------------------------------------------------------
-- Helper: every child the caller owns or is linked to.
-- security definer so policies can use it without the two tables' policies
-- reading each other (the infinite-recursion error).
-- ---------------------------------------------------------------------------
create or replace function private.user_child_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id from public.children where owner_id = (select auth.uid())
  union
  select child_id from public.child_members where user_id = (select auth.uid())
$$;

revoke all on function private.user_child_ids() from public;
grant usage on schema private to authenticated;
grant execute on function private.user_child_ids() to authenticated;

-- ---------------------------------------------------------------------------
-- Sign-up trigger: creates the profiles row with the role picked on /login
-- (passed as options.data.role in supabase.auth.signUp).
-- ---------------------------------------------------------------------------
create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'display_name', split_part(new.email, '@', 1)),
    case when new.raw_user_meta_data ->> 'role' = 'teacher' then 'teacher' else 'parent' end
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

-- ---------------------------------------------------------------------------
-- Parent links a teacher by email. Parents cannot read other users' emails,
-- so this runs with elevated rights but checks the caller owns the child.
-- ---------------------------------------------------------------------------
create or replace function public.add_teacher_by_email(p_child_id uuid, p_email text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_teacher uuid;
begin
  if not exists (
    select 1 from public.children where id = p_child_id and owner_id = (select auth.uid())
  ) then
    raise exception 'not your child';
  end if;

  select p.id into v_teacher
  from auth.users u
  join public.profiles p on p.id = u.id
  where lower(u.email) = lower(trim(p_email)) and p.role = 'teacher';

  if v_teacher is null then
    raise exception 'no teacher account with that email';
  end if;

  insert into public.child_members (child_id, user_id, role)
  values (p_child_id, v_teacher, 'teacher')
  on conflict do nothing;
end;
$$;

revoke all on function public.add_teacher_by_email(uuid, text) from public, anon;
grant execute on function public.add_teacher_by_email(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
alter table public.profiles      enable row level security;
alter table public.children      enable row level security;
alter table public.child_members enable row level security;
alter table public.assessments   enable row level security;
alter table public.calm_profiles enable row level security;
alter table public.devices       enable row level security;
alter table public.commands      enable row level security;
alter table public.events        enable row level security;

-- Grant only what the website needs. anon (logged out) gets nothing.
revoke all on public.profiles, public.children, public.child_members, public.assessments,
              public.calm_profiles, public.devices, public.commands, public.events
  from anon, authenticated;

grant select on public.profiles, public.children, public.child_members, public.assessments,
                public.calm_profiles, public.devices, public.commands, public.events
  to authenticated;
grant update (display_name)                         on public.profiles      to authenticated;
grant insert (nickname, age_band, consent_at)       on public.children      to authenticated;
grant update (nickname, age_band)                   on public.children      to authenticated;
grant delete                                        on public.children      to authenticated;
grant delete                                        on public.child_members to authenticated;
grant insert (child_id, answers)                    on public.assessments   to authenticated;
grant insert (child_id, version, profile, model)    on public.calm_profiles to authenticated;
grant update (profile, status, approved_at)         on public.calm_profiles to authenticated;
grant insert (device_id, child_id, type)            on public.commands      to authenticated;
grant update (helped)                               on public.events        to authenticated;

-- profiles: you see and rename yourself; you also see the names of teachers
-- and parents who share a child with you.
create policy "profiles: read self and people sharing a child"
  on public.profiles for select to authenticated
  using (
    id = (select auth.uid())
    or id in (select owner_id from public.children where id in (select private.user_child_ids()))
    or id in (select user_id from public.child_members where child_id in (select private.user_child_ids()))
  );
create policy "profiles: update self"
  on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- children
create policy "children: read own or linked"
  on public.children for select to authenticated
  using (id in (select private.user_child_ids()));
create policy "children: parents create their own"
  on public.children for insert to authenticated
  with check (
    owner_id = (select auth.uid())
    and exists (select 1 from public.profiles where id = (select auth.uid()) and role = 'parent')
  );
create policy "children: owner updates"
  on public.children for update to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy "children: owner deletes (delete my child's data)"
  on public.children for delete to authenticated
  using (owner_id = (select auth.uid()));

-- child_members
create policy "child_members: read own links and links on my children"
  on public.child_members for select to authenticated
  using (user_id = (select auth.uid()) or child_id in (select private.user_child_ids()));
create policy "child_members: owner removes a teacher"
  on public.child_members for delete to authenticated
  using (child_id in (select id from public.children where owner_id = (select auth.uid())));

-- assessments: owner only
create policy "assessments: owner reads"
  on public.assessments for select to authenticated
  using (child_id in (select id from public.children where owner_id = (select auth.uid())));
create policy "assessments: owner creates"
  on public.assessments for insert to authenticated
  with check (
    created_by = (select auth.uid())
    and child_id in (select id from public.children where owner_id = (select auth.uid()))
  );

-- calm_profiles: owner and linked teachers read; owner creates drafts and approves
create policy "calm_profiles: read own or linked"
  on public.calm_profiles for select to authenticated
  using (child_id in (select private.user_child_ids()));
create policy "calm_profiles: owner creates drafts"
  on public.calm_profiles for insert to authenticated
  with check (
    status = 'draft'
    and child_id in (select id from public.children where owner_id = (select auth.uid()))
  );
create policy "calm_profiles: owner edits and approves"
  on public.calm_profiles for update to authenticated
  using (child_id in (select id from public.children where owner_id = (select auth.uid())))
  with check (child_id in (select id from public.children where owner_id = (select auth.uid())));

-- devices: read only (device-api writes)
create policy "devices: read own or linked"
  on public.devices for select to authenticated
  using (child_id in (select private.user_child_ids()));

-- commands: linked users insert start/stop for their students' watches; no update/delete
create policy "commands: read own or linked"
  on public.commands for select to authenticated
  using (child_id in (select private.user_child_ids()));
create policy "commands: linked users send start/stop"
  on public.commands for insert to authenticated
  with check (
    created_by = (select auth.uid())
    and child_id in (select private.user_child_ids())
    and device_id in (select id from public.devices where child_id = commands.child_id)
  );

-- events: read own or linked; linked users set "did this help?"
create policy "events: read own or linked"
  on public.events for select to authenticated
  using (child_id in (select private.user_child_ids()));
create policy "events: linked users set helped"
  on public.events for update to authenticated
  using (child_id in (select private.user_child_ids()))
  with check (child_id in (select private.user_child_ids()));

-- ---------------------------------------------------------------------------
-- Realtime: class and parent pages update live
-- ---------------------------------------------------------------------------
alter publication supabase_realtime add table public.events, public.devices;
