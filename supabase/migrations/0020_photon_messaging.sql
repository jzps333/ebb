-- Texting (iMessage through Photon).
--
--   1. private.outbound_texts   queue the Mac bridge drains: login codes, relays, replies
--   2. private.text_threads     which child a texter is talking about right now
--   3. private.processed_texts  inbound message ids already handled (idempotency + rate limit)
--   4. relays                   a journal entry or comment is texted to the child's
--                               other adults (parent + linked teachers) who confirmed a phone
--   5. service-role API         public.ebb_text_* wrappers called by the messaging and
--                               sms-hook edge functions; nobody else may execute them
--
-- Phones are stored as E.164 ("+15551234567"). auth.users.phone has no "+".
-- Times are US Eastern, like the rest of the schema.

-- ---------------------------------------------------------------------------
-- 1-3. Tables (private schema: no client grants, not exposed by the API)
-- ---------------------------------------------------------------------------
create table private.outbound_texts (
  id          bigserial primary key,
  to_phone    text not null check (to_phone ~ '^\+[1-9][0-9]{6,14}$'),
  body        text not null check (char_length(body) between 1 and 1600),
  kind        text not null check (kind in ('otp', 'relay', 'reply')),
  created_at  timestamptz not null default now(),
  claimed_at  timestamptz,           -- lease, so a slow send is not picked up twice
  sent_at     timestamptz,
  attempts    int not null default 0,
  error       text
);
create index outbound_texts_pending_idx on private.outbound_texts (id) where sent_at is null;

create table private.text_threads (
  phone       text primary key,
  user_id     uuid not null references auth.users (id) on delete cascade,
  child_id    uuid references public.children (id) on delete cascade,
  updated_at  timestamptz not null default now()
);
create index text_threads_user_idx  on private.text_threads (user_id);
create index text_threads_child_idx on private.text_threads (child_id);

create table private.processed_texts (
  message_id  text primary key,
  phone       text,
  created_at  timestamptz not null default now()
);
create index processed_texts_phone_idx on private.processed_texts (phone, created_at desc);

alter table private.outbound_texts  enable row level security;
alter table private.text_threads    enable row level security;
alter table private.processed_texts enable row level security;
revoke all on private.outbound_texts, private.text_threads, private.processed_texts
  from public, anon, authenticated;
revoke all on sequence private.outbound_texts_id_seq from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
-- "+1 (555) 123-4567", "15551234567", "5551234567" -> "+15551234567"; junk -> null.
create or replace function private.e164(p_phone text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when d is null then null
    when char_length(d) = 10 then '+1' || d                 -- bare US number
    when char_length(d) between 8 and 15 and d !~ '^0' then '+' || d
    else null
  end
  from (select nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '') as d) x
$$;
revoke all on function private.e164(text) from public;

create or replace function private.enqueue_text(p_phone text, p_body text, p_kind text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_phone text := private.e164(p_phone);
  v_id bigint;
begin
  if v_phone is null or coalesce(trim(p_body), '') = '' then
    return null;
  end if;
  insert into private.outbound_texts (to_phone, body, kind)
  values (v_phone, left(p_body, 1600), p_kind)
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function private.enqueue_text(text, text, text) from public;

-- Is p_user the child's parent ('parent'), a linked teacher ('teacher'), or neither (null)?
create or replace function private.relation_to_child(p_user uuid, p_child uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when exists (select 1 from public.children c where c.id = p_child and c.owner_id = p_user) then 'parent'
    when exists (select 1 from public.child_members m where m.child_id = p_child and m.user_id = p_user) then 'teacher'
  end
$$;
revoke all on function private.relation_to_child(uuid, uuid) from public;

-- ---------------------------------------------------------------------------
-- 4. Relays
-- ---------------------------------------------------------------------------
-- Text p_body to every adult linked to p_child except p_author, if they have a
-- confirmed phone. "Ms. Rivera (Sam's teacher): …". Also points each
-- recipient's text thread at this child, so their reply lands in the right place.
-- Returns how many texts were queued.
create or replace function private.relay_text(p_child uuid, p_author uuid, p_body text, p_what text default null)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner  uuid;
  v_nick   text;
  v_rel    text;
  v_name   text;
  v_body   text;
  v_prefix text;
  v_n      int := 0;
  r        record;
begin
  select c.owner_id, c.nickname into v_owner, v_nick from public.children c where c.id = p_child;
  if v_owner is null then
    return 0;
  end if;

  v_rel := coalesce(private.relation_to_child(p_author, p_child), 'teacher');
  select nullif(trim(p.display_name), '') into v_name from public.profiles p where p.id = p_author;
  v_name := coalesce(v_name, case when v_rel = 'parent' then 'A parent' else 'A teacher' end);

  v_body := regexp_replace(trim(coalesce(p_body, '')), '\s+', ' ', 'g');
  if v_body = '' then
    return 0;
  end if;
  if char_length(v_body) > 320 then
    v_body := left(v_body, 317) || '…';
  end if;

  v_prefix := v_name || ' (' || v_nick || '''s ' || v_rel || ')' || coalesce(' ' || p_what, '');

  for r in
    select u.id as uid, private.e164(u.phone) as e164
    from (
      select v_owner as uid
      union
      select m.user_id from public.child_members m where m.child_id = p_child
    ) a
    join auth.users u on u.id = a.uid
    where a.uid <> p_author
      and coalesce(u.phone, '') <> ''
      and u.phone_confirmed_at is not null
      and u.deleted_at is null
  loop
    continue when r.e164 is null;
    insert into private.outbound_texts (to_phone, body, kind)
    values (r.e164, left(v_prefix || ': ' || v_body, 1600), 'relay');
    insert into private.text_threads as t (phone, user_id, child_id, updated_at)
    values (r.e164, r.uid, p_child, now())
    on conflict (phone) do update
      set user_id = excluded.user_id, child_id = excluded.child_id, updated_at = now();
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke all on function private.relay_text(uuid, uuid, text, text) from public;

-- Trigger: journal entries and comments are relayed. A relay problem must
-- never block the app's write, so errors become warnings.
create or replace function private.relay_journal()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_child uuid;
begin
  begin
    if tg_table_name = 'journal_comments' then
      select e.child_id into v_child from public.journal_entries e where e.id = new.entry_id;
      perform private.relay_text(v_child, new.author_id, new.body, null);
    else
      perform private.relay_text(new.child_id, new.author_id, new.body,
        case when new.kind = 'event' then 'wrote about a calm moment' else 'wrote today''s note' end);
    end if;
  exception when others then
    raise warning 'relay_journal skipped: %', sqlstate;
  end;
  return new;
end;
$$;
revoke all on function private.relay_journal() from public;

create trigger journal_comments_relay_text
  after insert on public.journal_comments
  for each row execute function private.relay_journal();

create trigger journal_entries_relay_text
  after insert on public.journal_entries
  for each row execute function private.relay_journal();

-- ---------------------------------------------------------------------------
-- Outbox (the bridge drains it)
-- ---------------------------------------------------------------------------
-- Claim up to p_limit unsent texts: codes first, codes older than 10 minutes
-- and relays older than a day are dropped, 5 attempts max, 2-minute lease.
create or replace function private.claim_outbox(p_limit int default 20)
returns table (id bigint, to_phone text, body text, kind text)
language sql
security definer
set search_path = ''
as $$
  update private.outbound_texts o
     set attempts = o.attempts + 1, claimed_at = now()
   where o.id in (
     select q.id
       from private.outbound_texts q
      where q.sent_at is null
        and q.attempts < 5
        and (q.claimed_at is null or q.claimed_at < now() - interval '2 minutes')
        and q.created_at > now() - case when q.kind = 'otp' then interval '10 minutes' else interval '1 day' end
      order by (q.kind = 'otp') desc, q.id
      limit least(greatest(coalesce(p_limit, 20), 1), 50)
      for update skip locked
   )
  returning o.id, o.to_phone, o.body, o.kind
$$;
revoke all on function private.claim_outbox(int) from public;

-- p_ids were delivered; p_errors is {"<id>": "message"} for failures (retried
-- on the next poll until attempts run out).
create or replace function private.mark_outbox(p_ids bigint[], p_errors jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update private.outbound_texts o
     set sent_at = now(), error = null
   where o.id = any (coalesce(p_ids, '{}'::bigint[])) and o.sent_at is null;

  update private.outbound_texts o
     set error = left(e.value, 500), claimed_at = null
    from jsonb_each_text(coalesce(p_errors, '{}'::jsonb)) e
   where e.key ~ '^\d+$' and o.id = e.key::bigint and o.sent_at is null;
end;
$$;
revoke all on function private.mark_outbox(bigint[], jsonb) from public;

-- ---------------------------------------------------------------------------
-- Inbound
-- ---------------------------------------------------------------------------
-- 'duplicate' if this message id was seen, 'rate_limited' past 30 texts an
-- hour from one phone, else 'ok' (and records it).
create or replace function private.begin_inbound(p_message_id text, p_phone text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_phone text := private.e164(p_phone);
  v_n int;
begin
  insert into private.processed_texts (message_id, phone)
  values (p_message_id, v_phone)
  on conflict (message_id) do nothing;
  if not found then
    return 'duplicate';
  end if;
  select count(*) into v_n from private.processed_texts
   where phone = v_phone and created_at > now() - interval '1 hour';
  if v_n > 30 then
    return 'rate_limited';
  end if;
  return 'ok';
end;
$$;
revoke all on function private.begin_inbound(text, text) from public;

-- Who is texting? Only confirmed phones count. Returns null for strangers.
create or replace function private.text_user(p_phone text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with ph as (select private.e164(p_phone) as e164),
  u as (
    select u.id
      from auth.users u, ph
     where ph.e164 is not null
       and u.phone in (substr(ph.e164, 2), ph.e164)
       and u.phone_confirmed_at is not null
       and u.deleted_at is null
       and (u.banned_until is null or u.banned_until < now())
     limit 1
  )
  select jsonb_build_object(
    'user_id', p.id,
    'display_name', p.display_name,
    'role', p.role,
    'children', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id,
               'nickname', c.nickname,
               'relation', case when c.owner_id = p.id then 'parent' else 'teacher' end)
             order by c.created_at)
        from public.children c
       where c.owner_id = p.id
          or c.id in (select m.child_id from public.child_members m where m.user_id = p.id)), '[]'::jsonb),
    'thread_child_id', (
      select t.child_id from private.text_threads t, ph
       where t.phone = ph.e164 and t.user_id = p.id and t.updated_at > now() - interval '14 days')
  )
  from u join public.profiles p on p.id = u.id
$$;
revoke all on function private.text_user(text) from public;

create or replace function private.set_text_thread(p_phone text, p_user uuid, p_child uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_phone text := private.e164(p_phone);
begin
  if v_phone is null then
    return;
  end if;
  if p_child is not null and private.relation_to_child(p_user, p_child) is null then
    raise exception 'not linked to this child';
  end if;
  insert into private.text_threads (phone, user_id, child_id, updated_at)
  values (v_phone, p_user, p_child, now())
  on conflict (phone) do update
    set user_id = excluded.user_id, child_id = excluded.child_id, updated_at = now();
end;
$$;
revoke all on function private.set_text_thread(text, uuid, uuid) from public;

-- Everything the texter may see about the child, for answering a question.
-- Same reach as the app (events, insights, journal: parent and linked
-- teachers alike). No locations, no assessments, no nickname (the caller has it).
create or replace function private.text_child_context(p_user uuid, p_child uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_out jsonb;
begin
  if private.relation_to_child(p_user, p_child) is null then
    raise exception 'not linked to this child';
  end if;
  select owner_id into v_owner from public.children where id = p_child;

  with ev as (
    select e.*, (e.started_at at time zone 'America/New_York') as local_at
      from public.events e
     where e.child_id = p_child and e.started_at > now() - interval '28 days'
  )
  select jsonb_build_object(
    'now_local', to_char(now() at time zone 'America/New_York', 'Dy YYYY-MM-DD HH24:MI'),
    'age_band', (select age_band from public.children where id = p_child),
    'asker_relation', private.relation_to_child(p_user, p_child),
    'calm_moments_last_14_days', coalesce((
      select jsonb_agg(jsonb_build_object(
               'when', to_char(local_at, 'Dy Mon DD HH24:MI'),
               'trigger', trigger,
               'minutes', case when ended_at is not null
                               then round((extract(epoch from ended_at - started_at) / 60)::numeric, 1) end,
               'teacher_said_helped', helped,
               'false_alarm', false_alarm,
               'child_felt', child_feeling,
               'agitation_before', round(agitation_before::numeric, 2),
               'agitation_after', round(agitation_after::numeric, 2),
               'recovery_seconds', recovery_seconds,
               'response_tier', tier)
             order by started_at desc)
        from (select * from ev where started_at > now() - interval '14 days'
              order by started_at desc limit 60) x), '[]'::jsonb),
    'stats_28_days', jsonb_build_object(
      'total', (select count(*) from ev),
      'last_7_days', (select count(*) from ev where started_at > now() - interval '7 days'),
      'previous_7_days', (select count(*) from ev where started_at <= now() - interval '7 days'
                                                    and started_at > now() - interval '14 days'),
      'avg_minutes', (select round(avg(extract(epoch from ended_at - started_at) / 60)::numeric, 1)
                        from ev where ended_at is not null),
      'helped', (select count(*) from ev where helped is true),
      'not_helped', (select count(*) from ev where helped is false),
      'false_alarms', (select count(*) from ev where false_alarm is true),
      'by_trigger', coalesce((select jsonb_object_agg(trigger, n)
                                from (select trigger, count(*) n from ev group by trigger) t), '{}'::jsonb),
      'busiest_time', (select to_char(local_at, 'Dy') || ' ' || extract(hour from local_at)::int || ':00'
                         from ev group by to_char(local_at, 'Dy'), extract(hour from local_at)
                         order by count(*) desc limit 1)
    ),
    'latest_weekly_report', (
      select jsonb_build_object('week_start', w.week_start, 'report', w.report)
        from public.weekly_insights w where w.child_id = p_child
       order by w.week_start desc limit 1),
    'journal_last_7_days', coalesce((
      select jsonb_agg(jsonb_build_object(
               'kind', j.kind,
               'day', j.day,
               'by', case when j.author_id = v_owner then 'parent' else 'teacher' end,
               'by_you', j.author_id = p_user,
               'written', to_char(j.created_at at time zone 'America/New_York', 'Dy Mon DD HH24:MI'),
               'text', left(j.body, 600),
               'comments', coalesce((
                  select jsonb_agg(jsonb_build_object(
                           'by', case when jc.author_id = v_owner then 'parent' else 'teacher' end,
                           'by_you', jc.author_id = p_user,
                           'text', left(jc.body, 300)) order by jc.created_at)
                    from public.journal_comments jc where jc.entry_id = j.id), '[]'::jsonb))
             order by j.created_at desc)
        from (select * from public.journal_entries
               where child_id = p_child and created_at > now() - interval '7 days'
               order by created_at desc limit 15) j), '[]'::jsonb)
  ) into v_out;
  return v_out;
end;
$$;
revoke all on function private.text_child_context(uuid, uuid) from public;

-- A texted note goes into the journal (and the relay trigger texts it on):
--   teacher: their own day entry for today (created with the note if missing),
--            otherwise a comment on it
--   parent:  a comment on today's newest entry for the child; if teachers have
--            not written today, the note is texted to them without being saved
-- Returns {"saved": "entry"|"comment"|"relayed", "recipients": n}.
create or replace function private.save_text_note(p_user uuid, p_child uuid, p_body text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rel   text := private.relation_to_child(p_user, p_child);
  v_today date := (now() at time zone 'America/New_York')::date;
  v_body  text := trim(coalesce(p_body, ''));
  v_entry uuid;
  v_n     int;
begin
  if v_rel is null then
    raise exception 'not linked to this child';
  end if;
  if v_body = '' then
    raise exception 'empty note';
  end if;

  if v_rel = 'teacher' then
    select id into v_entry from public.journal_entries
     where author_id = p_user and child_id = p_child and kind = 'day' and day = v_today;
    if v_entry is null then
      insert into public.journal_entries (child_id, kind, day, author_id, body)
      values (p_child, 'day', v_today, p_user, left(v_body, 5000));
      return jsonb_build_object('saved', 'entry');
    end if;
  else
    select id into v_entry from public.journal_entries
     where child_id = p_child
       and (created_at at time zone 'America/New_York')::date = v_today
     order by (kind = 'day') desc, created_at desc
     limit 1;
    if v_entry is null then
      v_n := private.relay_text(p_child, p_user, v_body, null);
      return jsonb_build_object('saved', 'relayed', 'recipients', v_n);
    end if;
  end if;

  insert into public.journal_comments (entry_id, author_id, body)
  values (v_entry, p_user, left(v_body, 2000));
  return jsonb_build_object('saved', 'comment');
end;
$$;
revoke all on function private.save_text_note(uuid, uuid, text) from public;

-- ---------------------------------------------------------------------------
-- 5. Service-role API (the edge functions call these through PostgREST rpc)
-- ---------------------------------------------------------------------------
create or replace function public.ebb_text_claim_outbox(p_limit int default 20)
returns table (id bigint, to_phone text, body text, kind text)
language sql security definer set search_path = ''
as $$ select * from private.claim_outbox(p_limit) $$;

create or replace function public.ebb_text_mark_sent(p_ids bigint[], p_errors jsonb default '{}'::jsonb)
returns void
language sql security definer set search_path = ''
as $$ select private.mark_outbox(p_ids, p_errors) $$;

create or replace function public.ebb_text_enqueue_otp(p_phone text, p_body text)
returns bigint
language sql security definer set search_path = ''
as $$ select private.enqueue_text(p_phone, p_body, 'otp') $$;

create or replace function public.ebb_text_begin_inbound(p_message_id text, p_phone text)
returns text
language sql security definer set search_path = ''
as $$ select private.begin_inbound(p_message_id, p_phone) $$;

create or replace function public.ebb_text_user(p_phone text)
returns jsonb
language sql security definer set search_path = ''
as $$ select private.text_user(p_phone) $$;

create or replace function public.ebb_text_set_thread(p_phone text, p_user uuid, p_child uuid)
returns void
language sql security definer set search_path = ''
as $$ select private.set_text_thread(p_phone, p_user, p_child) $$;

create or replace function public.ebb_text_child_context(p_user uuid, p_child uuid)
returns jsonb
language sql security definer set search_path = ''
as $$ select private.text_child_context(p_user, p_child) $$;

create or replace function public.ebb_text_save_note(p_user uuid, p_child uuid, p_body text)
returns jsonb
language sql security definer set search_path = ''
as $$ select private.save_text_note(p_user, p_child, p_body) $$;

revoke all on function public.ebb_text_claim_outbox(int)                from public, anon, authenticated;
revoke all on function public.ebb_text_mark_sent(bigint[], jsonb)        from public, anon, authenticated;
revoke all on function public.ebb_text_enqueue_otp(text, text)           from public, anon, authenticated;
revoke all on function public.ebb_text_begin_inbound(text, text)         from public, anon, authenticated;
revoke all on function public.ebb_text_user(text)                        from public, anon, authenticated;
revoke all on function public.ebb_text_set_thread(text, uuid, uuid)      from public, anon, authenticated;
revoke all on function public.ebb_text_child_context(uuid, uuid)         from public, anon, authenticated;
revoke all on function public.ebb_text_save_note(uuid, uuid, text)       from public, anon, authenticated;

grant execute on function public.ebb_text_claim_outbox(int)              to service_role;
grant execute on function public.ebb_text_mark_sent(bigint[], jsonb)     to service_role;
grant execute on function public.ebb_text_enqueue_otp(text, text)        to service_role;
grant execute on function public.ebb_text_begin_inbound(text, text)      to service_role;
grant execute on function public.ebb_text_user(text)                     to service_role;
grant execute on function public.ebb_text_set_thread(text, uuid, uuid)   to service_role;
grant execute on function public.ebb_text_child_context(uuid, uuid)      to service_role;
grant execute on function public.ebb_text_save_note(uuid, uuid, text)    to service_role;
