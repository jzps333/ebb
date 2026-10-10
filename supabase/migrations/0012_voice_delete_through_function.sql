-- Deleting a voice_clips or parent_voices row directly left the audio file in
-- the voice-clips bucket and the cloned voice at ElevenLabs. Deletion now goes
-- only through the voice function (action=delete_voice), which removes the
-- files and the ElevenLabs voice too.
--
-- Known gap: deleting a child or a parent account cascades these rows away
-- without that cleanup. Until a cleanup job exists, delete the voice in the
-- app first (docs/privacy.md).

revoke delete on public.voice_clips, public.parent_voices from authenticated;

alter policy "voice_clips: owner deletes" on public.voice_clips using (false);
alter policy "parent_voices: owner deletes" on public.parent_voices using (false);
