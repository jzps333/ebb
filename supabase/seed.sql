-- Demo data so the dashboards have something to show on video:
-- a demo parent and teacher (who can log in), one student "Sam" linked to both,
-- a demo watch, and a week of calm sessions ending today.
--
-- Demo logins (demo accounts only ever see this demo student):
--   parent.demo@ebb.test   teacher.demo@ebb.test
-- The password is NOT in git: replace __DEMO_PASSWORD__ before running, or
-- see supabase/demo-logins.local.txt (gitignored) on the machine that seeded it.
--
-- Safe to run again: fixed ids and "on conflict do nothing". Sessions are placed
-- relative to today, so a rerun on a later day adds that day's sessions.

do $$
declare
  demo_password constant text := '__DEMO_PASSWORD__';

  v_parent  constant uuid := 'd0000000-0000-4000-8000-000000000001';
  v_teacher constant uuid := 'd0000000-0000-4000-8000-000000000002';
  v_child   constant uuid := 'd0000000-0000-4000-8000-000000000003';
  v_device  constant uuid := 'd0000000-0000-4000-8000-000000000004';

  d          date;
  i          int;
  n          int;
  t          timestamptz;
  trig       text;
  len_s      int;
  cmd_id     uuid;
  r          double precision;
begin
  perform setseed(0.42);  -- same "random" week every run

  -- Users. Columns GoTrue reads as strings must be '' rather than NULL.
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change
  ) values
    ('00000000-0000-0000-0000-000000000000', v_parent, 'authenticated', 'authenticated',
     'parent.demo@ebb.test', extensions.crypt(demo_password, extensions.gen_salt('bf')), now(),
     '{"provider":"email","providers":["email"]}', '{"role":"parent","display_name":"Alex (demo parent)"}',
     now(), now(), '', '', '', ''),
    ('00000000-0000-0000-0000-000000000000', v_teacher, 'authenticated', 'authenticated',
     'teacher.demo@ebb.test', extensions.crypt(demo_password, extensions.gen_salt('bf')), now(),
     '{"provider":"email","providers":["email"]}', '{"role":"teacher","display_name":"Ms. Rivera (demo teacher)"}',
     now(), now(), '', '', '', '')
  on conflict (id) do nothing;  -- the sign-up trigger creates their profiles rows

  insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
  values
    (gen_random_uuid(), v_parent, v_parent::text, 'email',
     jsonb_build_object('sub', v_parent::text, 'email', 'parent.demo@ebb.test', 'email_verified', true), now(), now(), now()),
    (gen_random_uuid(), v_teacher, v_teacher::text, 'email',
     jsonb_build_object('sub', v_teacher::text, 'email', 'teacher.demo@ebb.test', 'email_verified', true), now(), now(), now())
  on conflict do nothing;

  insert into public.children (id, owner_id, nickname, age_band, consent_at)
  values (v_child, v_parent, 'Sam', '6-8', now() - interval '8 days')
  on conflict (id) do nothing;

  insert into public.child_members (child_id, user_id, role)
  values (v_child, v_teacher, 'teacher')
  on conflict do nothing;

  -- Not a real token: this demo watch can never log in to device-api.
  insert into public.devices (id, child_id, hardware_id, token_hash, last_seen_at, battery_pct, firmware_version)
  values (v_device, v_child, 'demo-watch', 'seed-demo-device-no-login', now(), 76, '0.1.0')
  on conflict (id) do nothing;

  -- A week of school-day sessions, 08:15-14:45 US Eastern.
  for d in select generate_series(current_date - 6, current_date, interval '1 day')::date loop
    n := 1 + floor(random() * 4)::int;  -- 1 to 4 sessions a day
    for i in 1..n loop
      t := (d + time '08:15' + make_interval(mins => floor(random() * 390)::int)) at time zone 'America/New_York';
      r := random();
      trig := case when r < 0.40 then 'teacher' when r < 0.70 then 'child_tap'
                   when r < 0.88 then 'motion' else 'noise' end;
      len_s := 60 + floor(random() * 121)::int;  -- 1 to 3 minutes (calm mode caps at 3)

      cmd_id := null;
      if trig = 'teacher' then
        insert into public.commands (device_id, child_id, type, created_by, created_at, delivered_at, done_at)
        values (v_device, v_child, 'start_calm', v_teacher, t - interval '2 seconds', t, t)
        returning id into cmd_id;
      end if;

      insert into public.events (device_id, child_id, trigger, command_id, started_by,
                                 started_at, ended_at, noise_db, motion_score, helped)
      values (
        v_device, v_child, trig, cmd_id,
        case when trig = 'teacher' then v_teacher end,
        t, t + make_interval(secs => len_s),
        case when trig = 'noise'  then round((72 + random() * 12)::numeric, 1) end,
        case when trig = 'motion' then round((0.6 + random() * 0.35)::numeric, 2) end,
        case when random() < 0.70 then true when random() < 0.5 then false end
      )
      on conflict (device_id, started_at) do nothing;
    end loop;
  end loop;
end $$;
