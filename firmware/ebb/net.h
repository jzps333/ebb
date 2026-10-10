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

// Downloads a full URL (no auth header) into flash at dest_path, via a
// temporary file so a failed download never leaves half a file behind.
// Returns the HTTP status (200 = saved) or a negative error.
int net_download(const String &url, const char *dest_path);

// True once NTP has set the real time (needed before any HTTPS call).
bool net_clock_ready();
bool net_connected();      // also kicks a reconnect if WiFi has been down a while

// path is appended to API_BASE_URL, e.g. "/device-api/poll?profile_version=0".
// Returns the HTTP status code (200 etc.), or a negative number on a network error:
//   -100 WiFi not connected, -101 bad URL, -102 clock not set yet (HTTPS waits
//   for NTP, because certificates cannot be checked against a 1970 clock),
//   other negatives are HTTPClient errors (-1 = could not connect / TLS failed).
int net_get(const String &path, String &body_out);
int net_post(const String &path, const String &json_body, String &body_out);
