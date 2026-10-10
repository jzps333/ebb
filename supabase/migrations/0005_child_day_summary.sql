-- One row per child per day for the parent dashboard ("how was Sam today?").
-- security_invoker: the view runs with the caller's rights, so the events RLS
-- policy still decides which children's rows each parent or teacher sees.
-- Days are US Eastern school days, so a 4 pm session is not counted as tomorrow (UTC).

create view public.child_day_summary
with (security_invoker = true)
as
select
  e.child_id,
  (e.started_at at time zone 'America/New_York')::date                as day,
  count(*)                                                            as sessions,
  round((sum(extract(epoch from coalesce(e.ended_at, now()) - e.started_at)) / 60.0)::numeric, 1)
                                                                      as calm_minutes,
  count(*) filter (where e.trigger = 'teacher')                       as by_teacher,
  count(*) filter (where e.trigger = 'child_tap')                     as by_child_tap,
  count(*) filter (where e.trigger = 'motion')                        as by_motion,
  count(*) filter (where e.trigger = 'noise')                         as by_noise,
  count(*) filter (where e.helped is true)                            as helped_yes,
  count(*) filter (where e.helped is false)                           as helped_no,
  count(*) filter (where e.ended_at is null)                          as active_now,
  min(e.started_at)                                                   as first_started_at,
  max(e.started_at)                                                   as last_started_at
from public.events e
where e.child_id is not null
group by e.child_id, (e.started_at at time zone 'America/New_York')::date;

revoke all on public.child_day_summary from anon, authenticated;
grant select on public.child_day_summary to authenticated;
