#pragma once

// Loops one MP3 from flash through the watch speaker (MAX98357A over I2S).
// Decoding runs on its own task so the breathing animation never waits on it.

void audio_begin();

// Main loop. path like "/audio/rain.mp3"; gain 0.0-1.0 (the speaker is loud,
// so calm mode uses about 0.05-0.2). Restarts if something else is playing.
void audio_play_loop(const char *path, float gain);
void audio_stop();
