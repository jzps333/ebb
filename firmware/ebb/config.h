#pragma once

// Tunable numbers. Secrets (WiFi, URL, token) live in secrets.h instead.

#define FIRMWARE_VERSION      "0.1.0"

// 0-3, each step turns the screen 90 degrees. LilyGoLib's own default is 2.
// If the screen is sideways or upside down, try 1, 3, 0. Touch follows automatically.
#define SCREEN_ROTATION       2

#define POLL_INTERVAL_MS      3000   // how often commands asks device-api/poll
#define HTTP_TIMEOUT_MS       5000   // give up on a request after this long
#define WIFI_RETRY_MS         10000  // wait this long before re-calling WiFi.begin()
