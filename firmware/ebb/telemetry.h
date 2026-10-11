#pragma once
#include <stdint.h>

// POST device-api/status: calm_active, battery, firmware version, the live
// agitation and tier, and the sensor samples for the app's live graph.
// The main loop records; the network task sends (it blocks on HTTP).

struct SensorSample {
    uint32_t at_ms;      // millis()
    float    motion;     // 0..1
    float    noise_db;   // NAN = no mic
    float    motion_z;
    float    noise_z;    // NAN = no mic
    float    agitation;
};

// Main loop. Adds a sample (kept while offline, newest SAMPLE_BUFFER_SIZE).
void telemetry_add_sample(const SensorSample &s);

// Main loop. Latest live state; a tier change is sent straight away.
void telemetry_set_state(float agitation, int tier, bool calm_active, int battery_pct);

// Network task: POST /status if one is due (every STATUS_POST_MS, or now on a tier change).
void telemetry_flush();
