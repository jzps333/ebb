-- Parent voice: a parent records ~1 minute in the app; the voice function sends
-- it straight to ElevenLabs (never stored), keeps only the resulting voice id,
-- and renders short phrases the parent picked into clips. The parent listens
-- to each clip and approves it; only approved clips reach the child's watch.

create table public.parent_voices (
  owner_id             uuid primary key references public.profiles (id) on delete cascade,
  elevenlabs_voice_id  text not null,
  consent_at           timestamptz not null,  -- "this is my own voice and I agree"
  created_at           timestamptz not null default now()
);

create table public.voice_clips (
  id            uuid primary key default gen_random_uuid(),
  child_id      uuid not null references public.children (id) on delete cascade,
  owner_id      uuid not null references public.profiles (id) on delete cascade,
  phrase        text not null check (char_length(phrase) between 1 and 80),
  storage_path  text not null,                      -- in the private voice-clips bucket
  status        text not null default 'draft' check (status in ('draft', 'approved')),
  created_at    timestamptz not null default now(),
  approved_at   timestamptz
);
create index voice_clips_child_idx on public.voice_clips (child_id, status);
create index voice_clips_owner_idx on public.voice_clips (owner_id);

alter table public.parent_voices enable row level security;
alter table public.voice_clips   enable row level security;

-- Rows are written by the voice Edge Function (service role). The parent reads
-- their own, approves clips and can delete them; teachers never see voice data.
revoke all on public.parent_voices, public.voice_clips from anon, authenticated;
grant select, delete on public.parent_voices to authenticated;
grant select, delete on public.voice_clips   to authenticated;
grant update (status, approved_at) on public.voice_clips to authenticated;

create policy "parent_voices: owner only"
  on public.parent_voices for select to authenticated
  using (owner_id = (select auth.uid()));
create policy "parent_voices: owner deletes"
  on public.parent_voices for delete to authenticated
  using (owner_id = (select auth.uid()));

create policy "voice_clips: owner reads"
  on public.voice_clips for select to authenticated
  using (owner_id = (select auth.uid()));
create policy "voice_clips: owner approves"
  on public.voice_clips for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));
create policy "voice_clips: owner deletes"
  on public.voice_clips for delete to authenticated
  using (owner_id = (select auth.uid()));

-- Private: clips are only reachable through short-lived signed URLs that the
-- voice function (for the parent) and device-api (for the child's watch) issue.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('voice-clips', 'voice-clips', false, 1048576, array['audio/mpeg'])
on conflict (id) do nothing;
