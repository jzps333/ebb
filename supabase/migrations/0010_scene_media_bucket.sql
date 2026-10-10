-- Public bucket for the watch's scene media (looping GIFs and MP3s). These are
-- generic calm scenes with no child data, so public read is fine and lets the
-- watch download them without a login. Only GIF and MP3, up to 5 MB each.
-- Upload media/out/video/*.gif to video/ and media/out/audio/*.mp3 to audio/.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('scene-media', 'scene-media', true, 5242880, array['image/gif', 'audio/mpeg'])
on conflict (id) do nothing;
