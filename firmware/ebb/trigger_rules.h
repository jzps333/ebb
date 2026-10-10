#pragma once

// Decides when motion or noise should start calm mode: motion for 10 s,
// noise for 5 s, 2-minute cooldown after a session. Build step 5.
// NOT BUILT YET: stub so the sketch compiles. Not called from ebb.ino.

// Returns true when an automatic trigger should start calm mode now.
bool trigger_rules_should_start(float motion_score, float noise_db);
void trigger_rules_session_ended();   // starts the cooldown
