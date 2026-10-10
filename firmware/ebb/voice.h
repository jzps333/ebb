#pragma once

// The parent's approved voice clips (ElevenLabs), kept in flash at
// /voice/<id>.mp3 and played now and then during calm mode.

// Main loop at boot: use the clips already in flash, so the voice works offline.
void voice_begin();

// Network task: every few minutes, fetch the approved list from
// device-api/voice, download new clips, delete removed ones.
void voice_sync();

// Main loop: path of the next clip to play (round-robin), or false if none.
bool voice_next_clip(char *path_out, size_t len);
