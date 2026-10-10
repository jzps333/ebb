#pragma once
#include <Arduino.h>

// WiFi connect/retry and HTTP(S) calls to device-api.
// net_get / net_post block until done, so call them only from the
// commands background task, never from loop() or an LVGL callback.

void net_begin();

// The device token sent as "Authorization: Bearer". Set by pairing (from flash
// or after QR pairing); empty means unpaired, and requests go out without it.
void net_set_token(const char *token);
bool net_has_token();
bool net_connected();      // also kicks a reconnect if WiFi has been down a while

// path is appended to API_BASE_URL, e.g. "/device-api/poll?profile_version=0".
// Returns the HTTP status code (200 etc.), or a negative number on a network error.
int net_get(const String &path, String &body_out);
int net_post(const String &path, const String &json_body, String &body_out);
