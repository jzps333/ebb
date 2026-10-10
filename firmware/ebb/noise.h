#pragma once

// Reads the PDM mic and returns a loudness number. Audio is never stored or sent.
// Build step 5. Start from LilyGO example peripheral/PDM_Noise_Detection.
// NOT BUILT YET: stub so the sketch compiles. Not called from ebb.ino.

void noise_begin();
float noise_db();       // current room loudness
