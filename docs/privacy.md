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
