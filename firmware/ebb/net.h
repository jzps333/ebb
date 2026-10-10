#pragma once
#include <Arduino.h>

// WiFi connect/retry and HTTP(S) calls to device-api.
// net_get / net_post block until done, so call them only from the
// commands background task, never from loop() or an LVGL callback.

void net_begin();
bool net_connected();      // also kicks a reconnect if WiFi has been down a while

// path is appended to API_BASE_URL, e.g. "/device-api/poll?profile_version=0".
// Returns the HTTP status code (200 etc.), or a negative number on a network error.
int net_get(const String &path, String &body_out);
int net_post(const String &path, const String &json_body, String &body_out);
