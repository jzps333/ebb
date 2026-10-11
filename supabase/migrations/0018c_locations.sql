-- Adaptive Ebb, part C: opt-in GPS. See 0018a.

-- ---------------------------------------------------------------------------
-- 7. locations: parent opt-in GPS
-- ---------------------------------------------------------------------------
create table public.locations (
  id          bigint generated always as identity primary key,
  child_id    uuid not null references public.children (id) on delete cascade,
  device_id   uuid references public.devices (id) on delete set null,
  event_id    uuid references public.events (id) on delete cascade,
  at          timestamptz not null,
  lat         double precision not null check (lat between -90 and 90),
  lng         double precision not null check (lng between -180 and 180),
  accuracy_m  real,
  kind        text not null check (kind in ('trail', 'calm'))
);
create index locations_child_at_idx on public.locations (child_id, at desc);
create index locations_device_idx on public.locations (device_id);
create index locations_event_idx on public.locations (event_id);

-- School hours: Monday-Friday, 08:00-15:00 New York time.
create or replace function private.is_school_hours(p_at timestamptz)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select extract(isodow from p_at at time zone 'America/New_York') between 1 and 5
     and (p_at at time zone 'America/New_York')::time >= time '08:00'
     and (p_at at time zone 'America/New_York')::time <  time '15:00'
$$;
grant execute on function private.is_school_hours(timestamptz) to authenticated;

alter table public.locations enable row level security;
-- The parent always sees their own child's points.
create policy "locations: parent reads"
  on public.locations for select to authenticated
  using (child_id in (select id from public.children where owner_id = (select auth.uid())));
-- A linked teacher sees points recorded in school hours, and only while it
-- is school hours now.
create policy "locations: teacher reads in school hours"
  on public.locations for select to authenticated
  using (
    private.is_school_hours(now())
    and private.is_school_hours(at)
    and child_id in (select child_id from public.child_members where user_id = (select auth.uid()))
  );
revoke all on public.locations from anon, authenticated;
grant select on public.locations to authenticated;

