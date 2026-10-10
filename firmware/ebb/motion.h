#pragma once

// Reads the BMA423 accelerometer and returns a repetitive-motion score
// (rocking, hand-flapping). Build step 5. Start from LilyGO example sensor/BMA423_Feature.
// NOT BUILT YET: stub so the sketch compiles. Not called from ebb.ino.

void motion_begin();
float motion_score();   // 0.0 = still, 1.0 = strong repetitive motion
