-- Teacher journal for the website. Teachers write an entry per tantrum (calm
-- event) and per day; the child's parent reads them and asks questions in a
-- comment thread that the teacher answers.

create table public.journal_entries (
  id          uuid primary key default gen_random_uuid(),
  child_id    uuid not null references public.children (id) on delete cascade,
  kind        text not null check (kind in ('event', 'day')),
  event_id    uuid references public.events (id) on delete cascade,  -- set when kind = 'event'
  day         date,                                                  -- set when kind = 'day' (school day, US Eastern)
  author_id   uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  body        text not null check (char_length(body) between 1 and 5000),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (
    (kind = 'event' and event_id is not null and day is null)
    or (kind = 'day' and day is not null and event_id is null)
  )
);

-- One entry per teacher per tantrum, and per teacher per child per day.
create unique index journal_entries_one_per_event on public.journal_entries (author_id, event_id) where kind = 'event';
create unique index journal_entries_one_per_day   on public.journal_entries (author_id, child_id, day) where kind = 'day';
create index journal_entries_child_idx  on public.journal_entries (child_id, created_at desc);
create index journal_entries_event_idx  on public.journal_entries (event_id);
create index journal_entries_author_idx on public.journal_entries (author_id);

-- Questions from the parent and answers from the teacher, under one entry.
create table public.journal_comments (
  id          uuid primary key default gen_random_uuid(),
  entry_id    uuid not null references public.journal_entries (id) on delete cascade,
  author_id   uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  body        text not null check (char_length(body) between 1 and 2000),
  created_at  timestamptz not null default now()
);
create index journal_comments_entry_idx  on public.journal_comments (entry_id, created_at);
create index journal_comments_author_idx on public.journal_comments (author_id);

-- Keep updated_at honest when a teacher edits an entry.
create or replace function private.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger journal_entries_touch
  before update on public.journal_entries
  for each row execute function private.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
alter table public.journal_entries  enable row level security;
alter table public.journal_comments enable row level security;

revoke all on public.journal_entries, public.journal_comments from anon, authenticated;
grant select on public.journal_entries, public.journal_comments to authenticated;
grant insert (child_id, kind, event_id, day, body) on public.journal_entries  to authenticated;
grant update (body)                                on public.journal_entries  to authenticated;
grant delete                                       on public.journal_entries  to authenticated;
grant insert (entry_id, body)                      on public.journal_comments to authenticated;
grant delete                                       on public.journal_comments to authenticated;

-- Entries: the parent and linked teachers read; only a linked teacher writes,
-- and a tantrum entry must point at an event of that same child.
create policy "journal_entries: read own or linked"
  on public.journal_entries for select to authenticated
  using (child_id in (select private.user_child_ids()));

create policy "journal_entries: linked teachers write"
  on public.journal_entries for insert to authenticated
  with check (
    author_id = (select auth.uid())
    and child_id in (select child_id from public.child_members where user_id = (select auth.uid()))
    and (event_id is null
         or event_id in (select id from public.events where child_id = journal_entries.child_id))
  );

create policy "journal_entries: author edits"
  on public.journal_entries for update to authenticated
  using (author_id = (select auth.uid()))
  with check (author_id = (select auth.uid()));

create policy "journal_entries: author deletes"
  on public.journal_entries for delete to authenticated
  using (author_id = (select auth.uid()));

-- Comments: anyone who can see the entry (its parent, its linked teachers)
-- can read the thread and add to it.
create policy "journal_comments: read on visible entries"
  on public.journal_comments for select to authenticated
  using (entry_id in (select id from public.journal_entries));

create policy "journal_comments: write on visible entries"
  on public.journal_comments for insert to authenticated
  with check (
    author_id = (select auth.uid())
    and entry_id in (select id from public.journal_entries)
  );

create policy "journal_comments: author deletes"
  on public.journal_comments for delete to authenticated
  using (author_id = (select auth.uid()));

-- The website updates live when a teacher writes or a parent asks.
alter publication supabase_realtime add table public.journal_entries, public.journal_comments;
