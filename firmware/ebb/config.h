#pragma once

// Tunable numbers. Secrets (WiFi, URL, token) live in secrets.h instead.

#define FIRMWARE_VERSION      "0.4.0"

// 0-3, each step turns the screen 90 degrees. LilyGoLib's own default is 2.
// If the screen is sideways or upside down, try 1, 3, 0. Touch follows automatically.
#define SCREEN_ROTATION       2

#define POLL_INTERVAL_MS      3000   // how often commands asks device-api/poll
#define HTTP_TIMEOUT_MS       5000   // give up on a request after this long
#define WIFI_RETRY_MS         10000  // wait this long before re-calling WiFi.begin()

#define CALM_MAX_MS           (3UL * 60 * 1000)  // calm mode ends by itself after 3 minutes
#define EVENT_QUEUE_SIZE      20     // calm reports kept while offline

// ---- Adaptive sensing (docs/adaptive-contract.md) ---------------------------
// The mic's dB is only approximate: dBFS + this offset, never calibrated.
#define NOISE_DB_OFFSET       94.0f
#define SAMPLE_EVERY_MS       5000   // one sensor sample for the app's live graph
#define SAMPLE_BUFFER_SIZE    60     // samples kept while offline (device-api takes <= 60)
#define STATUS_POST_MS        5000   // POST /status at most this often (sooner on a tier change)
#define AUTO_COOLDOWN_MS      (2UL * 60 * 1000)   // no automatic calm for 2 min after a session
#define BASELINE_SAVE_MS      (10UL * 60 * 1000)  // child's baseline saved to flash this often
#define CHECKIN_MS            10000  // "how do you feel?" screen after calm, then it closes itself
#define GPS_TRAIL_MS          (5UL * 60 * 1000)   // one trail point every 5 min (gps_enabled only)
#define GPS_FIX_MAX_AGE_MS    (10UL * 60 * 1000)  // older fixes are never reported
#define GPS_QUEUE_SIZE        20     // trail points kept while offline (device-api takes <= 20)
