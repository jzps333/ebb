#pragma once
#include <stddef.h>

// The parent-approved weekly scene set (up to 6 video + sound pairs). Calm
// mode plays the next one each session; the scene id goes into the event so
// "did it help" can be counted per scene.

struct Scene {
    char id[24];     // e.g. "space_rain"
    char video[12];  // /video/<video>.gif
    char sound[16];  // /audio/<sound>.mp3, or "none"
};

void scenes_begin();                 // main loop at boot: load the set saved in flash
void scenes_sync();                  // network task: fetch the approved set every few minutes
bool scenes_next(Scene &out);        // main loop: next scene in rotation; false if no set
