#include "profile_store.h"

// TODO: real implementation (see profile_store.h).

void profile_store_begin() {}
int profile_store_version() { return 0; }
bool profile_store_save(int version, const String &json) { return false; }
String profile_store_load() { return String(); }
