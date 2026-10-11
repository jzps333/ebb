-- Adaptive Ebb, part B: scene bandit, pattern stats, weekly insights. See 0018a.

-- ---------------------------------------------------------------------------
-- 4. Scene bandit (Thompson sampling)
-- ---------------------------------------------------------------------------
-- Time-of-day context for a calm moment: morning (<12), afternoon (12-17),
-- evening, in the school's time zone.
create or replace function private.time_bucket(p_at timestamptz)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when extract(hour from p_at at time zone 'America/New_York') < 12 then 'morning'
    when extract(hour from p_at at time zone 'America/New_York') < 17 then 'afternoon'
    else 'evening' end
$$;

-- One draw from Beta(a, b) for whole a, b >= 1: the a-th smallest of
-- a + b - 1 uniform numbers. Counts are capped so this stays cheap.
create or replace function private.beta_sample(p_a int, p_b int)
returns double precision
language sql
volatile
set search_path = ''
as $$
  select u from (
    select random() as u from generate_series(1, least(p_a, 60) + least(p_b, 60) - 1)
  ) draws
  order by u
  offset greatest(least(p_a, 60), 1) - 1
  limit 1
$$;

-- Helped / didn't-help counts for one child and scene over 8 weeks, optionally
-- only in one time bucket. Unrated moments and false alarms don't count.
create or replace function private.scene_counts(p_child_id uuid, p_scene_id text, p_bucket text default null)
returns table (helped int, not_helped int)
language sql
stable
security definer
set search_path = ''
as $$
  select count(*) filter (where e.helped is true)::int,
         count(*) filter (where e.helped is false)::int
  from public.events e
  where e.child_id = p_child_id and e.scene_id = p_scene_id
    and e.started_at > now() - interval '56 days'
    and e.false_alarm is not true
    and (p_bucket is null or private.time_bucket(e.started_at) = p_bucket)
$$;
revoke all on function private.scene_counts(uuid, text, text) from public;

-- Which scene of this week's approved set to play next, for device-api.
-- Each scene's chance of helping is drawn from Beta(1 + helped, 1 + not) for
-- the current time of day (falling back to all-day counts when this bucket
-- has fewer than 2 ratings); the highest draw wins. Untried scenes still
-- get picked sometimes, so the watch keeps learning.
create or replace function private.pick_scene(p_child_id uuid)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_bucket text := private.time_bucket(now());
  v_best   text;
  v_best_p double precision := -1;
  v_p      double precision;
  r        record;
  c        record;
begin
  for r in
    select i.scene_id from public.scene_set_items i
    join public.scene_sets s on s.id = i.set_id
    where s.child_id = p_child_id and s.status = 'approved'
      and s.week_start = (select max(week_start) from public.scene_sets
                          where child_id = p_child_id and status = 'approved'
                            and week_start <= (now() at time zone 'America/New_York')::date)
  loop
    select * into c from private.scene_counts(p_child_id, r.scene_id, v_bucket);
    if c.helped + c.not_helped < 2 then
      select * into c from private.scene_counts(p_child_id, r.scene_id, null);
    end if;
    v_p := private.beta_sample(1 + c.helped, 1 + c.not_helped);
    if v_p > v_best_p then v_best_p := v_p; v_best := r.scene_id; end if;
  end loop;
  return v_best;
end;
$$;
revoke all on function private.pick_scene(uuid) from public;

-- make_scene_set: anchors as before; the free slots are filled by Thompson
-- draws instead of a fixed score, so promising-but-untried scenes get a turn.
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

  -- Fill to 6 by Thompson draws (theme scenes get a small head start).
  for v_scene in
    select s.id from public.scenes s
    cross join lateral private.scene_counts(p_child_id, s.id, null) c
    where s.active and not (s.id = any (v_picks))
    order by private.beta_sample(1 + c.helped, 1 + c.not_helped)
             + case when s.video = v_theme then 0.1 else 0 end desc
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

-- What the app shows: per scene and time bucket, how often it helped, the
-- posterior mean of Beta(1 + helped, 1 + not) and a 90% band (normal approx).
create or replace function public.scene_stats(p_child_id uuid)
returns table (scene_id text, title text, bucket text, helped int, not_helped int,
               mean double precision, low double precision, high double precision)
language sql
stable
security definer
set search_path = ''
as $$
  with b as (select unnest(array['all', 'morning', 'afternoon', 'evening']) as bucket),
  stat_rows as (
    select s.id, s.title, b.bucket, c.helped, c.not_helped
    from public.scenes s cross join b
    cross join lateral private.scene_counts(p_child_id, s.id, nullif(b.bucket, 'all')) c
    where s.active and p_child_id in (select private.user_child_ids())
  )
  select id, title, bucket, helped, not_helped,
         (1.0 + helped) / (2 + helped + not_helped) as mean,
         greatest(0, (1.0 + helped) / (2 + helped + not_helped)
           - 1.645 * sqrt(((1.0 + helped) * (1.0 + not_helped)) / ((2.0 + helped + not_helped) ^ 2 * (3.0 + helped + not_helped)))),
         least(1, (1.0 + helped) / (2 + helped + not_helped)
           + 1.645 * sqrt(((1.0 + helped) * (1.0 + not_helped)) / ((2.0 + helped + not_helped) ^ 2 * (3.0 + helped + not_helped))))
  from stat_rows
$$;
revoke all on function public.scene_stats(uuid) from public, anon;
grant execute on function public.scene_stats(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Pattern stats (for the heatmap and the AI report)
-- ---------------------------------------------------------------------------
create or replace function public.child_pattern_stats(p_child_id uuid, p_days int default 28)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with e as (
    select e.*, (e.started_at at time zone 'America/New_York') as local_at
    from public.events e
    where e.child_id = p_child_id
      and e.started_at > now() - make_interval(days => least(greatest(p_days, 1), 90))
      and p_child_id in (select private.user_child_ids())
  )
  select jsonb_build_object(
    'days', least(greatest(p_days, 1), 90),
    'total', (select count(*) from e),
    'heatmap', coalesce((
      select jsonb_agg(jsonb_build_object('dow', h.dow, 'hour', h.hr, 'count', h.n) order by h.dow, h.hr)
      from (select extract(isodow from local_at)::int as dow, extract(hour from local_at)::int as hr, count(*) as n
            from e group by 1, 2) h), '[]'::jsonb),
    'by_trigger', coalesce((
      select jsonb_object_agg(trigger, jsonb_build_object(
               'count', n, 'helped', h, 'not_helped', nh, 'false_alarms', fa))
      from (select trigger, count(*) n,
                   count(*) filter (where helped is true) h,
                   count(*) filter (where helped is false) nh,
                   count(*) filter (where false_alarm is true) fa
            from e group by trigger) t), '{}'::jsonb),
    'avg_minutes', (select round(avg(extract(epoch from ended_at - started_at) / 60)::numeric, 1)
                    from e where ended_at is not null),
    'avg_agitation_peak', (select round(avg(agitation_peak)::numeric, 2) from e where agitation_peak is not null),
    'busiest', (select jsonb_build_object('dow', b.dow, 'hour', b.hr, 'count', b.n)
                from (select extract(isodow from local_at)::int as dow, extract(hour from local_at)::int as hr,
                             count(*) as n
                      from e group by 1, 2 order by 3 desc limit 1) b)
  )
$$;
revoke all on function public.child_pattern_stats(uuid, int) from public, anon;
grant execute on function public.child_pattern_stats(uuid, int) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. weekly_insights (written by the insights edge function)
-- ---------------------------------------------------------------------------
create table public.weekly_insights (
  id          uuid primary key default gen_random_uuid(),
  child_id    uuid not null references public.children (id) on delete cascade,
  week_start  date not null,
  stats       jsonb not null,
  report      jsonb not null,
  model       text,
  created_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now(),
  unique (child_id, week_start)
);
create index weekly_insights_created_by_idx on public.weekly_insights (created_by);

alter table public.weekly_insights enable row level security;
create policy "weekly_insights: read own or linked"
  on public.weekly_insights for select to authenticated
  using (child_id in (select private.user_child_ids()));
revoke all on public.weekly_insights from anon, authenticated;
grant select on public.weekly_insights to authenticated;

