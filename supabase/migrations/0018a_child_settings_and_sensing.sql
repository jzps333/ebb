-- Adaptive Ebb: the watch senses rising agitation, starts calm by itself,
-- and the system learns from the teacher's ratings.
--
--   1. child_settings     what the watch follows (auto-start, sensitivity, GPS opt-in)
--   2. sensor_samples     the watch's live agitation readings (kept 2 days)
--   3. self-tuning        "false alarm" / "helped" on an auto-start nudges sensitivity
--   4. scene bandit       Thompson sampling picks the scene most likely to help now
--   5. pattern stats      calm moments by weekday x hour, triggers, what helped
--   6. weekly_insights    AI report written by the insights edge function
--   7. locations          opt-in GPS trail + calm pins; teachers only in school hours
--   8. retention          pg_cron deletes old samples (2 days) and locations (30 days)

-- ---------------------------------------------------------------------------
-- 1. child_settings
-- ---------------------------------------------------------------------------
create table public.child_settings (
  child_id        uuid primary key references public.children (id) on delete cascade,
  auto_motion     boolean not null default false,
  auto_noise      boolean not null default false,
  -- How many standard deviations above the child's own baseline counts as
  -- agitation. Learned from ratings; lower = starts calm sooner.
  motion_k        real not null default 2.5 check (motion_k between 1.5 and 5),
  noise_k         real not null default 2.5 check (noise_k between 1.5 and 5),
  gps_enabled     boolean not null default false,
  gps_consent_at  timestamptz,
  updated_at      timestamptz not null default now(),
  constraint child_settings_gps_needs_consent check (not gps_enabled or gps_consent_at is not null)
);

alter table public.child_settings enable row level security;

create policy "child_settings: read own or linked"
  on public.child_settings for select to authenticated
  using (child_id in (select private.user_child_ids()));
create policy "child_settings: parent changes"
  on public.child_settings for update to authenticated
  using (child_id in (select id from public.children where owner_id = (select auth.uid())))
  with check (child_id in (select id from public.children where owner_id = (select auth.uid())));

revoke all on public.child_settings from anon, authenticated;
grant select on public.child_settings to authenticated;
-- Sensitivity (motion_k / noise_k) is only changed by the learning trigger.
grant update (auto_motion, auto_noise, gps_enabled, gps_consent_at) on public.child_settings to authenticated;

create trigger child_settings_touch
  before update on public.child_settings
  for each row execute function private.touch_updated_at();

-- Every child gets a settings row.
create or replace function private.create_child_settings()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.child_settings (child_id) values (new.id) on conflict do nothing;
  return new;
end;
$$;
revoke all on function private.create_child_settings() from public;

create trigger children_create_settings
  after insert on public.children
  for each row execute function private.create_child_settings();

insert into public.child_settings (child_id) select id from public.children on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 2. sensor_samples: one row per watch reading (about every 5 s while awake)
-- ---------------------------------------------------------------------------
create table public.sensor_samples (
  id         bigint generated always as identity primary key,
  child_id   uuid not null references public.children (id) on delete cascade,
  device_id  uuid references public.devices (id) on delete set null,
  at         timestamptz not null,
  motion     real,     -- repetitive-motion score 0..1
  noise_db   real,     -- room loudness, dB (never audio)
  motion_z   real,     -- standard deviations above the child's own baseline
  noise_z    real,
  agitation  real      -- 0..1+, 1 = at the auto-start line
);
create index sensor_samples_child_at_idx on public.sensor_samples (child_id, at desc);
create index sensor_samples_device_idx on public.sensor_samples (device_id);

alter table public.sensor_samples enable row level security;
create policy "sensor_samples: read own or linked"
  on public.sensor_samples for select to authenticated
  using (child_id in (select private.user_child_ids()));
revoke all on public.sensor_samples from anon, authenticated;
grant select on public.sensor_samples to authenticated;

alter publication supabase_realtime add table public.sensor_samples;

-- ---------------------------------------------------------------------------
-- 3. Self-tuning sensitivity
-- ---------------------------------------------------------------------------
alter table public.events
  add column false_alarm    boolean,
  add column agitation_peak real;
grant update (false_alarm) on public.events to authenticated;  -- teacher-only by the existing policy

create table public.sensitivity_log (
  id        bigint generated always as identity primary key,
  child_id  uuid not null references public.children (id) on delete cascade,
  event_id  uuid references public.events (id) on delete set null,
  at        timestamptz not null default now(),
  signal    text not null check (signal in ('motion', 'noise')),
  old_k     real not null,
  new_k     real not null,
  reason    text not null
);
create index sensitivity_log_child_idx on public.sensitivity_log (child_id, at desc);
create index sensitivity_log_event_idx on public.sensitivity_log (event_id);

alter table public.sensitivity_log enable row level security;
create policy "sensitivity_log: read own or linked"
  on public.sensitivity_log for select to authenticated
  using (child_id in (select private.user_child_ids()));
revoke all on public.sensitivity_log from anon, authenticated;
grant select on public.sensitivity_log to authenticated;

-- An auto-start the teacher calls a false alarm makes that signal less
-- sensitive (k + 0.3); one that helped makes it a little more sensitive
-- (k - 0.1), so calm arrives earlier next time.
create or replace function private.tune_sensitivity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old   real;
  v_new   real;
  v_why   text;
begin
  if new.trigger not in ('motion', 'noise') then return new; end if;

  if new.false_alarm is true and old.false_alarm is distinct from true then
    v_why := 'false alarm';
  elsif new.helped is true and old.helped is distinct from true and new.false_alarm is not true then
    v_why := 'helped';
  else
    return new;
  end if;

  select case when new.trigger = 'motion' then motion_k else noise_k end
    into v_old from public.child_settings where child_id = new.child_id;
  if v_old is null then return new; end if;

  v_new := case when v_why = 'false alarm' then least(5, v_old + 0.3) else greatest(1.5, v_old - 0.1) end;
  if v_new = v_old then return new; end if;

  if new.trigger = 'motion' then
    update public.child_settings set motion_k = v_new where child_id = new.child_id;
  else
    update public.child_settings set noise_k = v_new where child_id = new.child_id;
  end if;

  insert into public.sensitivity_log (child_id, event_id, signal, old_k, new_k, reason)
  values (new.child_id, new.id, new.trigger, v_old, v_new, v_why);
  return new;
end;
$$;
revoke all on function private.tune_sensitivity() from public;

create trigger events_tune_sensitivity
  after update of helped, false_alarm on public.events
  for each row execute function private.tune_sensitivity();

