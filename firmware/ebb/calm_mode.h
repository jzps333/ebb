#pragma once

// Calm mode: full-screen breathing circle with a haptic pulse on each breath in.
// Call calm_mode_init() once after beginLvglHelper(), then start/stop at will.

void calm_mode_init();
void start_calm();
void stop_calm();
bool calm_is_running();
