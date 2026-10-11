#pragma once
#include <Arduino.h>
#include <ArduinoJson.h>

// Per-child adaptive settings from device-api/poll's "settings", saved in
// flash so automatic calm keeps working offline after a reboot. Also holds
// the server's "scene_pick" (the scene most likely to help right now).
// Written by the network task, read by the main loop, so access is locked.

struct AdaptiveSettings {
    bool  auto_motion;   // repetitive motion may start calm by itself
    bool  auto_noise;    // loud room may start calm by itself
    float motion_k;      // z-score that counts as "agitated" (1.5-5, tuned by the server)
    float noise_k;
    bool  gps_enabled;   // parent opted in (with consent) to location
};

void settings_begin();                         // main loop at boot: load from flash
AdaptiveSettings settings_get();               // any task: a copy

// Network task: apply poll's "settings" object (null/missing = keep ours)
// and "scene_pick" (null/missing = none).
void settings_apply_poll(JsonVariantConst settings, JsonVariantConst scene_pick);

// Any task: the server's scene pick, or false if there is none.
bool settings_scene_pick(char *out, size_t len);
