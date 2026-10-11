#include <Arduino.h>
#include <ArduinoJson.h>
#include "telemetry.h"
#include "net.h"
#include "commands.h"
#include "config.h"

struct LiveState {
    float agitation;
    int   tier;
    bool  calm_active;
    int   battery_pct;  // -1 = unknown / no battery
};

// Written by the main loop, read by the network task: all behind the lock.
static SensorSample samples[SAMPLE_BUFFER_SIZE];
static int          sample_count = 0;
static LiveState    live = { 0, 0, false, -1 };
static bool         tier_changed = false;
static portMUX_TYPE mux = portMUX_INITIALIZER_UNLOCKED;

void telemetry_add_sample(const SensorSample &s)
{
    taskENTER_CRITICAL(&mux);
    if (sample_count == SAMPLE_BUFFER_SIZE) {
        memmove(&samples[0], &samples[1], sizeof(SensorSample) * (SAMPLE_BUFFER_SIZE - 1));
        sample_count--;
    }
    samples[sample_count++] = s;
    taskEXIT_CRITICAL(&mux);
}

void telemetry_set_state(float agitation, int tier, bool calm_active, int battery_pct)
{
    taskENTER_CRITICAL(&mux);
    bool changed = tier != live.tier;
    live = { agitation, tier, calm_active, battery_pct };
    if (changed) tier_changed = true;
    taskEXIT_CRITICAL(&mux);
    if (changed) commands_wake();  // the app's "rising" banner should not wait
}

static float round2(float v)
{
    return roundf(v * 100) / 100;
}

static void put_number(JsonObject o, const char *key, float v)
{
    if (isnan(v) || isinf(v)) o[key] = nullptr;  // JSON has no NaN
    else                      o[key] = round2(v);
}

void telemetry_flush()
{
    static uint32_t last_post = 0;
    static bool     posted_once = false;

    taskENTER_CRITICAL(&mux);
    bool urgent = tier_changed;
    taskEXIT_CRITICAL(&mux);
    if (posted_once && !urgent && millis() - last_post < STATUS_POST_MS) return;

    // Copy what is waiting (static: network task only, keeps it off the stack).
    static SensorSample batch[SAMPLE_BUFFER_SIZE];
    taskENTER_CRITICAL(&mux);
    int n = sample_count;
    memcpy(batch, samples, sizeof(SensorSample) * n);
    LiveState state = live;
    tier_changed = false;
    taskEXIT_CRITICAL(&mux);

    // { "calm_active": false, "battery_pct": 82, "firmware_version": "0.4.0",
    //   "agitation": 0.42, "tier": 1,
    //   "samples": [ { "at": "…", "motion": 0.1, "noise_db": 58.2,
    //                  "motion_z": 0.4, "noise_z": 1.1, "agitation": 0.42 } ] }
    JsonDocument doc;
    doc["calm_active"] = state.calm_active;
    if (state.battery_pct >= 0) doc["battery_pct"] = state.battery_pct;
    doc["firmware_version"] = FIRMWARE_VERSION;
    doc["agitation"] = round2(state.agitation);
    doc["tier"] = state.tier;
    JsonArray arr = doc["samples"].to<JsonArray>();
    char at[24];
    int included = 0;
    for (int i = 0; i < n; i++) {
        if (!net_iso_time(batch[i].at_ms, at, sizeof(at))) break;  // clock not set yet: keep them
        JsonObject o = arr.add<JsonObject>();
        o["at"] = at;
        put_number(o, "motion", batch[i].motion);
        put_number(o, "noise_db", batch[i].noise_db);
        put_number(o, "motion_z", batch[i].motion_z);
        put_number(o, "noise_z", batch[i].noise_z);
        put_number(o, "agitation", batch[i].agitation);
        included++;
    }

    String body, response;
    serializeJson(doc, body);
    int code = net_post("/device-api/status", body, response);
    if (code == -100 || code == -102) return;  // WiFi / clock not ready yet
    posted_once = true;
    last_post = millis();

    if (code == 200 || (code >= 400 && code < 500)) {
        // 4xx would fail forever with the same samples: drop them, like event_log.
        if (code != 200) Serial.printf("[telemetry] status rejected %d: %s\n", code, response.c_str());
        taskENTER_CRITICAL(&mux);
        int sent = included < sample_count ? included : sample_count;
        memmove(&samples[0], &samples[sent], sizeof(SensorSample) * (sample_count - sent));
        sample_count -= sent;
        taskEXIT_CRITICAL(&mux);
    } else {
        Serial.printf("[telemetry] status failed (%d), %d sample(s) kept\n", code, n);
    }
}
