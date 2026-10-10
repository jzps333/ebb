#pragma once

// Calm mode: full-screen breathing circle with a haptic pulse on each breath in.
// Call calm_mode_init() once after beginLvglHelper(), then start/stop at will.

void calm_mode_init();
// trigger: "teacher", "motion", "noise" or "child_tap". command_id: the teacher
// command that caused it, if any. Both go into the calm session report.
void start_calm(const char *trigger = "child_tap", const char *command_id = "");
void stop_calm();
bool calm_is_running();
