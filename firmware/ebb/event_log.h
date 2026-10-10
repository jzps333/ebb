#pragma once

// Posts start and end of every calm session to device-api/events; queues
// them while offline. Build step 3.
// NOT BUILT YET: stub so the sketch compiles. Not called from ebb.ino.

// trigger: "teacher", "motion", "noise" or "child_tap" (matches the events table).
void event_log_started(const char *trigger, const char *command_id);
void event_log_ended();
void event_log_flush();   // send anything queued; call from the network task
