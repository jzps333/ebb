-- Weekly scene sets. A scene is a looping video + a sound from the
-- scene-media bucket. Each child gets 6 scenes per week, picked from what
-- helped before plus their calm profile's theme; the parent approves the set;
-- the watch plays the next scene each calm session and reports which one,
-- so "did it help" can be counted per scene.

create table public.scenes (
  id          text primary key,              -- e.g. 'ocean_rain'
  title       text not null,
  video       text not null,                 -- scene-media/<video>.gif
  sound       text not null default 'none',  -- scene-media/<sound>.mp3, or 'none'
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

insert into public.scenes (id, title, video, sound) values
  ('ocean_ocean',      'Ocean waves',            'ocean',   'ocean'),
  ('ocean_rain',       'Ocean in the rain',      'ocean',   'rain'),
  ('forest_rain',      'Leaves and rain',        'forest',  'rain'),
  ('forest_piano',     'Leaves and soft piano',  'forest',  'soft_piano'),
  ('animals_ocean',    'Clownfish reef',         'animals', 'ocean'),
  ('animals_piano',    'Clownfish and piano',    'animals', 'soft_piano'),
  ('space_brown',      'Earth and quiet hum',    'space',   'brown_noise'),
  ('space_piano',      'Earth and soft piano',   'space',   'soft_piano'),
  ('space_rain',       'Earth and rain',         'space',   'rain'),
  ('shapes_piano',     'Bubbles and piano',      'shapes',  'soft_piano'),
  ('shapes_rain',      'Bubbles and rain',       'shapes',  'rain'),
  ('shapes_brown',     'Bubbles and quiet hum',  'shapes',  'brown_noise')
on conflict (id) do nothing;

create table public.scene_sets (
  id           uuid primary key default gen_random_uuid(),
  child_id     uuid not null references public.children (id) on delete cascade,
  week_start   date not null,                -- Monday, US Eastern
  status       text not null default 'draft' check (status in ('draft', 'approved')),
  created_at   timestamptz not null default now(),
  approved_at  timestamptz,
  unique (child_id, week_start)
);
create index scene_sets_child_idx on public.scene_sets (child_id, week_start desc);

create table public.scene_set_items (
  set_id     uuid not null references public.scene_sets (id) on delete cascade,
  position   int  not null check (position between 1 and 6),
  scene_id   text not null references public.scenes (id),
  is_anchor  boolean not null default false,   -- kept every week (predictability)
  primary key (set_id, position)
);
create index scene_set_items_scene_idx on public.scene_set_items (scene_id);

alter table public.events add column scene_id text references public.scenes (id) on delete set null;
create index events_scene_idx on public.events (child_id, scene_id);

-- ---------------------------------------------------------------------------
-- RLS: everyone signed in reads the library; parent and linked teachers read
-- a child's sets; only the parent approves sets and swaps scenes. Sets are
-- created by make_scene_set().
-- ---------------------------------------------------------------------------
alter table public.scenes          enable row level security;
alter table public.scene_sets      enable row level security;
alter table public.scene_set_items enable row level security;

revoke all on public.scenes, public.scene_sets, public.scene_set_items from anon, authenticated;
grant select on public.scenes, public.scene_sets, public.scene_set_items to authenticated;
grant update (status, approved_at) on public.scene_sets      to authenticated;
grant update (scene_id)            on public.scene_set_items to authenticated;

create policy "scenes: library is readable" on public.scenes
  for select to authenticated using (active);

create policy "scene_sets: read own or linked" on public.scene_sets
  for select to authenticated using (child_id in (select private.user_child_ids()));
create policy "scene_sets: parent approves" on public.scene_sets
  for update to authenticated
  using (child_id in (select id from public.children where owner_id = (select auth.uid())))
  with check (child_id in (select id from public.children where owner_id = (select auth.uid())));

create policy "scene_set_items: read with the set" on public.scene_set_items
  for select to authenticated using (set_id in (select id from public.scene_sets));
create policy "scene_set_items: parent swaps scenes" on public.scene_set_items
  for update to authenticated
  using (set_id in (select s.id from public.scene_sets s join public.children c on c.id = s.child_id
                    where c.owner_id = (select auth.uid())))
  with check (set_id in (select s.id from public.scene_sets s join public.children c on c.id = s.child_id
                         where c.owner_id = (select auth.uid())));

-- ---------------------------------------------------------------------------
-- make_scene_set(child): builds (or rebuilds) the draft set for this week, or
-- for next week once this week's set is approved. Returns the set id.
--   position 1: anchor = the calm profile's theme (its sound if it has one)
--   position 2: anchor = the scene that helped most in the last 4 weeks
--   3-6: by how much they helped, then the profile theme, then variety;
--        scenes rated "didn't help" twice or more net are left out.
-- ---------------------------------------------------------------------------
-- Net "did it help" for one scene and child over the last 4 weeks (+1 helped, -1 didn't).
create or replace function private.scene_score(p_child_id uuid, p_scene_id text)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(case helped when true then 1 when false then -1 else 0 end), 0)::int
  from public.events
  where child_id = p_child_id and scene_id = p_scene_id and started_at > now() - interval '28 days'
$$;
revoke all on function private.scene_score(uuid, text) from public;

create or replace function public.make_scene_set(p_child_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_week    date := date_trunc('week', (now() at time zone 'America/New_York'))::date;
  v_theme   text;
  v_sound   text;
  v_set     uuid;
  v_status  text;
  v_picks   text[] := '{}';
  v_anchor  boolean[] := '{}';
  v_scene   text;
  i         int;
begin
  if not exists (select 1 from public.children where id = p_child_id and owner_id = v_uid) then
    raise exception 'not your child';
  end if;

  -- This week's set is already approved: plan next week's.
  select status into v_status from public.scene_sets where child_id = p_child_id and week_start = v_week;
  if v_status = 'approved' then v_week := v_week + 7; end if;

  select profile ->> 'theme', profile ->> 'sound' into v_theme, v_sound
  from public.calm_profiles where child_id = p_child_id and status = 'approved'
  order by version desc limit 1;
  v_theme := coalesce(v_theme, 'ocean');

  -- Anchor 1: the profile's theme, matching its sound when possible.
  select s.id into v_scene from public.scenes s
  where s.active and s.video = v_theme
  order by (s.sound = v_sound) desc, private.scene_score(p_child_id, s.id) desc, s.id limit 1;
  if v_scene is not null then v_picks := v_picks || v_scene; v_anchor := v_anchor || true; end if;

  -- Anchor 2: what has helped most, if anything clearly has.
  v_scene := null;
  select s.id into v_scene from public.scenes s
  where s.active and not (s.id = any (v_picks)) and private.scene_score(p_child_id, s.id) > 0
  order by private.scene_score(p_child_id, s.id) desc limit 1;
  if v_scene is not null then v_picks := v_picks || v_scene; v_anchor := v_anchor || true; end if;

  -- Fill to 6: helped first, then the profile theme, then variety.
  for v_scene in
    select s.id from public.scenes s
    where s.active and not (s.id = any (v_picks)) and private.scene_score(p_child_id, s.id) > -2
    order by private.scene_score(p_child_id, s.id) desc, (s.video = v_theme) desc, random()
  loop
    exit when array_length(v_picks, 1) >= 6;
    v_picks := v_picks || v_scene;
    v_anchor := v_anchor || false;
  end loop;

  insert into public.scene_sets (child_id, week_start)
  values (p_child_id, v_week)
  on conflict (child_id, week_start) do update set status = 'draft', approved_at = null
  returning id into v_set;

  for i in 1 .. coalesce(array_length(v_picks, 1), 0) loop
    insert into public.scene_set_items (set_id, position, scene_id, is_anchor)
    values (v_set, i, v_picks[i], v_anchor[i])
    on conflict (set_id, position) do update set scene_id = excluded.scene_id, is_anchor = excluded.is_anchor;
  end loop;
  return v_set;
end;
$$;

revoke all on function public.make_scene_set(uuid) from public, anon;
grant execute on function public.make_scene_set(uuid) to authenticated;
