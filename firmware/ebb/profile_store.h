#pragma once
#include <Arduino.h>

// The approved calm profile, saved in flash so calm mode looks and sounds
// right even offline. Arrives in device-api/poll's "profile" field.

struct CalmProfile {
    int  version;               // 0 = none yet (defaults below)
    char theme[12];             // ocean | space | forest | shapes | animals
    char colors[2][10];         // e.g. "blue", "teal"; second may be ""
    char breath_pattern[16];    // slow_4_4 | slow_4_6 | box_4_4_4_4 | none
    char vibration[8];          // off | gentle | medium
    char sound[16];             // none | rain | ocean | soft_piano | brown_noise
    char volume[8];             // off | low | medium
    char calm_message[48];
};

void profile_store_begin();            // main loop, before commands_begin
CalmProfile profile_store_get();       // any task: a copy of the current profile
int  profile_store_version();          // what poll sends as profile_version

// Network task: save a profile JSON object from poll. Returns true if it was
// valid and newer than the one we had.
bool profile_store_save_json(const String &json);

// 0xRRGGBB for a profile colour name.
uint32_t profile_color_hex(const char *name);
