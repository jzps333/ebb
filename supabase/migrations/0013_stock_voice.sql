-- A parent can pick a built-in ElevenLabs voice instead of cloning their own.
-- kind tells the voice function whether the ElevenLabs voice belongs to us
-- ('clone': delete it at ElevenLabs when the parent deletes) or is one of
-- ElevenLabs' stock voices ('stock': never delete). consent_at stays required:
-- for a stock voice it records when the parent chose it.
alter table public.parent_voices
  add column kind text not null default 'clone' check (kind in ('clone', 'stock'));
