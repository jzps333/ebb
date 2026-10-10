# Privacy

Ebb is designed around COPPA (US children's privacy rule) from day one, because it is a connected device used by children under 13. This is a summary for building, not legal advice; the rule was amended on April 22, 2025, so check the current version before a real launch. Before a school pilot, ask the school whether this data counts as an education record under FERPA.

## What is stored, and what is not

| Stored | Not stored |
|---|---|
| Child nickname and age band | Full name, birthday, school, photo |
| Assessment answers | Any audio |
| Calm sessions: time, trigger, who started it, loudness and motion scores | Location or GPS (the watch has GPS; it stays off) |
| Parent and teacher emails | Raw motion or sound data (only summary numbers) |

## How it is protected
- The parent gives consent when creating the student profile and can **delete the child's data** anytime from the child page; that removes the child row and everything under it.
- Row Level Security: each teacher and parent only sees students they are linked to.
- The microphone only computes a loudness number on the watch. No audio is ever recorded or sent.
- `ANTHROPIC_API_KEY` and the Supabase secret key live only in Supabase function secrets. The website uses only the publishable key. The watch holds only its own device token; the database stores only its hash.
- Parents approve every AI profile before it reaches the watch.

## Parent voice (ElevenLabs)
- Only a parent can clone a voice, only their own, after ticking a consent box in the app (time stored in `parent_voices.consent_at`).
- The recording goes from the app straight to ElevenLabs through the `voice` function. It is never stored by Ebb, and the app deletes its copy after upload.
- Ebb keeps only the ElevenLabs voice id and the short phrase clips the parent made. Clips sit in a private bucket and reach the watch only after the parent approves each one, through signed links that expire in an hour.
- Teachers never see voice data.
- "Delete my voice" in the app removes the voice at ElevenLabs and every clip. **Known gap:** deleting a child or the parent account does not yet run that cleanup, so delete the voice in the app first.
