#pragma once

// Saves the last approved calm profile in flash (Preferences) so it works
// offline. Build step 4.
// NOT BUILT YET: stub so the sketch compiles. Not called from ebb.ino.

#include <Arduino.h>

void profile_store_begin();
int  profile_store_version();               // 0 = no profile yet
bool profile_store_save(int version, const String &json);
String profile_store_load();               // empty if none
