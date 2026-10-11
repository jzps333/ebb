#pragma once

// Room loudness from the PDM mic (I2S port 0, 16 kHz) on its own low-priority
// task: RMS of 100 ms frames -> dBFS -> approximate dB (+ NOISE_DB_OFFSET).
// Only that number is kept. Audio is never stored or sent.

void  noise_begin();     // main loop at boot, after watch.begin()
float noise_db();        // any task: loudness, smoothed over ~1 s; NAN if no mic
