#include <Arduino.h>
#include <ArduinoJson.h>
#include "event_log.h"
#include "net.h"
#include "commands.h"
#include "config.h"
#include "gps.h"

// One report. A session produces two: the start (ended = false) and the end
// (ended = true). Both carry the same started time, so the server can match them.
struct Event {
    char     trigger[12];
    char     command_id[40];
    char     scene_id[24];
    char     child_feeling[8];  // "" = no answer
    uint32_t started_ms;  // millis() when calm mode started
    uint32_t ended_ms;    // millis() when it ended (only if ended)
    bool     ended;
    float    motion;          // reading at the start
    float    noise_db;        // NAN = no mic
    float    agitation_peak;  // end report only; < 0 = unknown
    int8_t   tier;            // end report only; 0 = none
    bool     has_fix;         // start report only
    GpsFix   fix;
};

// Written by the main loop, read by the network task, so every access to
// these goes through the critical section below.
static Event        pending[EVENT_QUEUE_SIZE];
static int          pending_count = 0;
static portMUX_TYPE pending_mux   = portMUX_INITIALIZER_UNLOCKED;

// The session in progress, so event_log_ended() knows what it is ending.
static Event current;
static bool  in_session = false;

static void enqueue(const Event &e)
{
    taskENTER_CRITICAL(&pending_mux);
    if (pending_count == EVENT_QUEUE_SIZE) {
        // Full after a long time offline: drop the oldest, keep the newest.
        memmove(&pending[0], &pending[1], sizeof(Event) * (EVENT_QUEUE_SIZE - 1));
        pending_count--;
    }
    pending[pending_count++] = e;
    taskEXIT_CRITICAL(&pending_mux);

    commands_wake();  // send now instead of waiting for the next 3 s poll
}

void event_log_started(const char *trigger, const char *command_id, const char *scene_id,
                       float motion, float noise_db)
{
    memset(&current, 0, sizeof(current));
    strlcpy(current.trigger, trigger, sizeof(current.trigger));
    strlcpy(current.command_id, command_id ? command_id : "", sizeof(current.command_id));
    strlcpy(current.scene_id, scene_id ? scene_id : "", sizeof(current.scene_id));
    current.started_ms     = millis();
    current.motion         = motion;
    current.noise_db       = noise_db;
    current.agitation_peak = -1;
    current.has_fix        = gps_latest(current.fix);  // false unless gps_enabled and fresh
    in_session = true;
    enqueue(current);
}

void event_log_ended(uint32_t ended_ms, const char *child_feeling, float agitation_peak, int tier)
{
    if (!in_session) return;
    in_session = false;
    current.ended          = true;
    current.ended_ms       = ended_ms;
    current.agitation_peak = agitation_peak;
    current.tier           = tier;
    current.has_fix        = false;  // the start report already placed the session
    strlcpy(current.child_feeling, child_feeling ? child_feeling : "", sizeof(current.child_feeling));
    enqueue(current);
}

static float round2(float v)
{
    return roundf(v * 100) / 100;
}

void event_log_flush()
{
    // Copy what is waiting, so the HTTP call happens without holding the lock.
    // Static: only the network task calls this, and it keeps 3 KB off its stack.
    static Event batch[EVENT_QUEUE_SIZE];
    taskENTER_CRITICAL(&pending_mux);
    int n = pending_count;
    memcpy(batch, pending, sizeof(Event) * n);
    taskEXIT_CRITICAL(&pending_mux);
    if (n == 0) return;

    // { "events": [ { "trigger": "motion", "command_id": null, "started_at": "…",
    //                 "ended_at": "…", "noise_db": 62, "motion_score": 0.2,
    //                 "agitation_peak": 1.3, "tier": 2, "child_feeling": "better",
    //                 "lat": …, "lng": …, "accuracy_m": 12 } ] }
    JsonDocument doc;
    JsonArray events = doc["events"].to<JsonArray>();
    char started_at[24], ended_at[24];
    for (int i = 0; i < n; i++) {
        const Event &b = batch[i];
        if (!net_iso_time(b.started_ms, started_at, sizeof(started_at))) return;  // retry once the clock is set
        JsonObject e = events.add<JsonObject>();
        e["trigger"] = b.trigger;
        if (b.command_id[0]) e["command_id"] = b.command_id;
        else                 e["command_id"] = nullptr;
        e["started_at"] = started_at;
        if (b.ended && net_iso_time(b.ended_ms, ended_at, sizeof(ended_at))) e["ended_at"] = ended_at;
        else                                                                 e["ended_at"] = nullptr;
        if (b.scene_id[0]) e["scene_id"] = b.scene_id;
        if (isnan(b.noise_db)) e["noise_db"] = nullptr;
        else                   e["noise_db"] = round2(b.noise_db);
        e["motion_score"] = round2(b.motion);
        if (b.ended) {
            if (b.agitation_peak >= 0) e["agitation_peak"] = round2(b.agitation_peak);
            if (b.tier >= 1) e["tier"] = b.tier;  // events.tier is 1-3; 0 = left out
            if (b.child_feeling[0]) e["child_feeling"] = b.child_feeling;
        }
        if (b.has_fix) {
            e["lat"]        = serialized(String(b.fix.lat, 6));  // full precision, not float's 7 digits
            e["lng"]        = serialized(String(b.fix.lng, 6));
            e["accuracy_m"] = round2(b.fix.accuracy_m);
        }
    }

    String body, response;
    serializeJson(doc, body);
    int code = net_post("/device-api/events", body, response);

    if (code == 200 || (code >= 400 && code < 500)) {
        // 200: saved. 4xx: the server rejected this data, and resending the
        // same thing would fail forever, so drop it rather than block new events.
        if (code != 200) Serial.printf("[event_log] rejected %d: %s\n", code, response.c_str());
        else             Serial.printf("[event_log] sent %d event(s): %s\n", n, response.c_str());

        // Remove only the n we sent; more may have been added meanwhile.
        taskENTER_CRITICAL(&pending_mux);
        int sent = n < pending_count ? n : pending_count;
        memmove(&pending[0], &pending[sent], sizeof(Event) * (pending_count - sent));
        pending_count -= sent;
        taskEXIT_CRITICAL(&pending_mux);
    } else if (code != -100 && code != -102) {  // WiFi / clock not ready yet
        Serial.printf("[event_log] send failed (%d), %d event(s) kept for later\n", code, n);
    }
}
