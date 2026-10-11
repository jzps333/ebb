#pragma once

// Reads the BMA423 accelerometer at ~25 Hz and scores repetitive motion
// (rocking, hand-flapping): high-passed magnitude over a 128-sample window,
// energy x periodicity (autocorrelation peak for 0.5-3 Hz).
// Main loop only: the BMA423 shares I2C with touch and the PMU.

void  motion_begin();     // after watch.begin()
void  motion_update();    // every loop(); takes a sample when one is due
float motion_score();     // 0.0 = still, 1.0 = strong repetitive motion
bool  motion_available(); // false if the accelerometer did not answer at boot
