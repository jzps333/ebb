-- Outcomes, live escalation and risk forecast.
--
--   1. events get objective outcomes: agitation before/after, how long it took
--      to settle, and the child's own check-in on the watch (better/same/worse).
--   2. devices carry the live agitation level and response tier (realtime),
--      so the app can warn adults before calm mode even starts.
--   3. scene_counts uses a combined reward: the teacher's rating when there is
--      one, otherwise the child's check-in, otherwise the measured drop.
--   4. risk_forecast: empirical-Bayes rate of calm moments per weekday x hour,
--      shrunk toward the child's overall rate, for the next hours.

-- ---------------------------------------------------------------------------
-- 1. Outcomes on events
-- ---------------------------------------------------------------------------
alter table public.events
  add column child_feeling      text check (child_feeling in ('better', 'same', 'worse')),
  add column agitation_before   real,   -- mean agitation over the 60 s before start
  add column agitation_after    real,   -- mean agitation over the 60 s after end
  add column recovery_seconds   int,    -- start -> first sample back under 0.5
  add column tier               int check (tier between 1 and 3);  -- highest response tier reached

-- Fill the outcome columns from sensor_samples. Called by device-api when a
-- session ends (and safe to call again).
create or replace function private.compute_event_outcome(p_event_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  e record;
begin
  select id, child_id, started_at, ended_at into e from public.events where id = p_event_id;
  if e.id is null or e.ended_at is null then return; end if;

  update public.events set
    agitation_before = (select avg(agitation) from public.sensor_samples
                        where child_id = e.child_id and at between e.started_at - interval '60 seconds' and e.started_at),
    agitation_after  = (select avg(agitation) from public.sensor_samples
                        where child_id = e.child_id and at between e.ended_at and e.ended_at + interval '60 seconds'),
    agitation_peak   = coalesce(agitation_peak,
                       (select max(agitation) from public.sensor_samples
                        where child_id = e.child_id and at between e.started_at - interval '60 seconds' and e.ended_at)),
    recovery_seconds = (select extract(epoch from min(at) - e.started_at)::int from public.sensor_samples
                        where child_id = e.child_id and at > e.started_at and at <= e.ended_at + interval '120 seconds'
                          and agitation < 0.5)
  where id = p_event_id;
end;
$$;
revoke all on function private.compute_event_outcome(uuid) from public;

-- ---------------------------------------------------------------------------
-- 2. Live agitation on devices
-- ---------------------------------------------------------------------------
alter table public.devices
  add column agitation     real,
  add column agitation_at  timestamptz,
  add column tier          int not null default 0 check (tier between 0 and 3);
-- 0 settled, 1 rising (wrist breathing cue), 2 calm mode, 3 needs an adult

-- ---------------------------------------------------------------------------
-- 3. Combined reward for the scene bandit
-- ---------------------------------------------------------------------------
-- Success when the teacher said it helped; otherwise when the child said
-- "better"; otherwise when measured agitation fell by at least 40%.
-- Failure on the opposite signals. Neither when nothing is known.
create or replace function private.event_success(
  p_helped boolean, p_feeling text, p_before real, p_after real)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case
    when p_helped is not null then p_helped
    when p_feeling = 'better' then true
    when p_feeling = 'worse' then false
    when p_before is not null and p_after is not null and p_before > 0.3 then p_after <= p_before * 0.6
    else null end
$$;

create or replace function private.scene_counts(p_child_id uuid, p_scene_id text, p_bucket text default null)
returns table (helped int, not_helped int)
language sql
stable
security definer
set search_path = ''
as $$
  select count(*) filter (where s is true)::int, count(*) filter (where s is false)::int
  from (
    select private.event_success(e.helped, e.child_feeling, e.agitation_before, e.agitation_after) as s
    from public.events e
    where e.child_id = p_child_id and e.scene_id = p_scene_id
      and e.started_at > now() - interval '56 days'
      and e.false_alarm is not true
      and (p_bucket is null or private.time_bucket(e.started_at) = p_bucket)
  ) x
$$;
revoke all on function private.scene_counts(uuid, text, text) from public;

-- ---------------------------------------------------------------------------
-- 4. Risk forecast
-- ---------------------------------------------------------------------------
-- For each of the next p_hours hours: expected calm moments in that hour,
-- from a Gamma-Poisson (empirical Bayes) estimate. Each weekday-hour cell has
-- n events over w weeks of history; its rate is shrunk toward the child's
-- overall hourly rate with prior strength 2 weeks:
--   rate = (n + 2 * overall) / (w + 2)
-- risk = 1 - exp(-rate) is the chance of at least one calm moment.
create or replace function public.risk_forecast(p_child_id uuid, p_hours int default 8)
returns table (hour_start timestamptz, expected double precision, risk double precision, level text)
language sql
stable
security definer
set search_path = ''
as $$
  with hist as (
    select started_at at time zone 'America/New_York' as local_at
    from public.events
    where child_id = p_child_id and started_at > now() - interval '56 days'
      and false_alarm is not true
      and p_child_id in (select private.user_child_ids())
  ),
  span as (
    select greatest(1.0, least(8.0,
      extract(epoch from now() - coalesce((select min(started_at) from public.events where child_id = p_child_id), now()))
      / 604800.0)) as weeks
  ),
  overall as (
    -- events per weekday-hour cell per week, averaged over school-ish hours (7-18)
    select (select count(*) from hist where extract(hour from local_at) between 7 and 18)
           / (5.0 * 12.0 * (select weeks from span)) as rate
  ),
  hours as (
    select date_trunc('hour', now()) + make_interval(hours => g) as h
    from generate_series(1, least(greatest(p_hours, 1), 24)) g
  ),
  cells as (
    select h.h,
           (select count(*) from hist
            where extract(isodow from local_at) = extract(isodow from h.h at time zone 'America/New_York')
              and extract(hour from local_at) = extract(hour from h.h at time zone 'America/New_York')) as n
    from hours h
  )
  select c.h,
         (c.n + 2 * o.rate) / ((select weeks from span) + 2) as expected,
         1 - exp(-((c.n + 2 * o.rate) / ((select weeks from span) + 2))) as risk,
         case when 1 - exp(-((c.n + 2 * o.rate) / ((select weeks from span) + 2))) >= 0.5 then 'high'
              when 1 - exp(-((c.n + 2 * o.rate) / ((select weeks from span) + 2))) >= 0.2 then 'medium'
              else 'low' end
  from cells c cross join overall o
  order by c.h
$$;
revoke all on function public.risk_forecast(uuid, int) from public, anon;
grant execute on function public.risk_forecast(uuid, int) to authenticated;
