#pragma once
#include <stdint.h>

// Turns motion and noise into one agitation level against the child's own
// baseline, and responds in tiers (docs/adaptive-contract.md):
//   0 settled
//   1 rising   >= 0.6 for 5 s  -> slow haptic breathing cue on the wrist
//   2 calm     >= 1.0 for 10 s (motion) / 5 s (noise) -> start_calm("motion"|"noise")
//   3 adult    still >= 1.0 after 60 s of calm -> reported in status
//   back to 0 when < 0.4 for 10 s; no automatic calm for 2 min after a session.
// Main loop only (it reads motion, drives the haptic motor and starts calm).

void  agitation_begin();          // after settings_begin(): loads the baseline from flash
void  agitation_update();         // every loop(); does its work at 5 Hz

float agitation_level();          // smoothed, 1.0 = the auto-start line
int   agitation_tier();           // 0-3

// calm_mode calls these. Ended returns the session's agitation peak and
// highest tier, and starts the 2-minute cooldown.
void  agitation_session_started();
void  agitation_session_ended(float &peak, int &tier);

void  agitation_simulate(uint32_t ms);  // Serial 'g': force agitation high (motion) for a demo
void  agitation_print();                // Serial 'a'
void  agitation_reset_baseline();       // new child (unpair): learn their normal from scratch
