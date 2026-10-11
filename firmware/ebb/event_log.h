#pragma once
#include <stdint.h>

// Reports the start and end of every calm session to device-api/events.
// The start report is what fires the live alert to the teacher and parent.
// Reports wait in memory while offline and go out together on reconnect.

// trigger: "teacher", "motion", "noise" or "child_tap" (matches the events table).
// command_id: the teacher command's id, or "" when the watch started on its own.
// scene_id: the weekly scene that played ("" if none), for per-scene "did it help".
// motion / noise_db: the readings at the start (noise_db NAN = no mic).
// The latest GPS fix (gps_enabled, <= 10 min old) goes on the start report.
// Called from the main loop (calm_mode).
void event_log_started(const char *trigger, const char *command_id, const char *scene_id,
                       float motion, float noise_db);

// ended_ms: millis() when calm stopped (the report itself waits for the
// check-in). child_feeling: "better" / "same" / "worse", or NULL if no answer.
// tier: highest response tier of the session, 0 = none (sent as null).
void event_log_ended(uint32_t ended_ms, const char *child_feeling, float agitation_peak, int tier);

// Sends anything waiting. Called from the network task only (it blocks on HTTP).
void event_log_flush();
