#pragma once

// Reports the start and end of every calm session to device-api/events.
// The start report is what fires the live alert to the teacher and parent.
// Reports wait in memory while offline and go out together on reconnect.

// trigger: "teacher", "motion", "noise" or "child_tap" (matches the events table).
// command_id: the teacher command's id, or "" when the watch started on its own.
// Called from the main loop (calm_mode).
void event_log_started(const char *trigger, const char *command_id);
void event_log_ended();

// Sends anything waiting. Called from the network task only (it blocks on HTTP).
void event_log_flush();
