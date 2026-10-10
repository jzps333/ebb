#include <Arduino.h>
#include <ArduinoJson.h>
#include <time.h>
#include <sys/time.h>
#include "event_log.h"
#include "net.h"
#include "commands.h"
#include "config.h"

// One report. A session produces two: the start (ended = false) and the end
// (ended = true). Both carry the same started time, so the server can match them.
struct Event {
    char     trigger[12];
    char     command_id[40];
    uint32_t started_ms;  // millis() when calm mode started
    uint32_t ended_ms;    // millis() when it ended (only if ended)
    bool     ended;
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

void event_log_started(const char *trigger, const char *command_id)
{
    memset(&current, 0, sizeof(current));
    strlcpy(current.trigger, trigger, sizeof(current.trigger));
    strlcpy(current.command_id, command_id ? command_id : "", sizeof(current.command_id));
    current.started_ms = millis();
    in_session = true;
    enqueue(current);
}

void event_log_ended()
{
    if (!in_session) return;
    in_session = false;
    current.ended    = true;
    current.ended_ms = millis();
    enqueue(current);
}

// Turns a millis() timestamp into "2026-10-10T18:22:01Z" using the clock
// NTP set. Returns false until the clock has been set.
//
// The boot time (real clock minus millis) is worked out once and reused, so
// the same millis() always gives the same string. Recomputing it each call
// could round to a different second, and the server matches a session's start
// and end reports by started_at.
static bool to_iso(uint32_t ms, char *out, size_t len)
{
    static int64_t boot_epoch_ms = 0;
    if (boot_epoch_ms == 0) {
        struct timeval tv;
        gettimeofday(&tv, nullptr);
        if (tv.tv_sec < 1700000000) return false;  // still 1970: NTP hasn't answered yet
        boot_epoch_ms = (int64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000 - (int64_t)millis();
    }
    time_t t = (time_t)((boot_epoch_ms + ms) / 1000);
    struct tm tm;
    gmtime_r(&t, &tm);
    strftime(out, len, "%Y-%m-%dT%H:%M:%SZ", &tm);
    return true;
}

void event_log_flush()
{
    // Copy what is waiting, so the HTTP call happens without holding the lock.
    Event batch[EVENT_QUEUE_SIZE];
    taskENTER_CRITICAL(&pending_mux);
    int n = pending_count;
    memcpy(batch, pending, sizeof(Event) * n);
    taskEXIT_CRITICAL(&pending_mux);
    if (n == 0) return;

    // Shape from the plan:
    // { "events": [ { "trigger": "teacher", "command_id": "…", "started_at": "…",
    //                 "ended_at": "…", "noise_db": 62, "motion_score": 0.2 } ] }
    JsonDocument doc;
    JsonArray events = doc["events"].to<JsonArray>();
    char started_at[24], ended_at[24];
    for (int i = 0; i < n; i++) {
        if (!to_iso(batch[i].started_ms, started_at, sizeof(started_at))) return;  // retry once the clock is set
        JsonObject e = events.add<JsonObject>();
        e["trigger"] = batch[i].trigger;
        if (batch[i].command_id[0]) e["command_id"] = batch[i].command_id;
        else                        e["command_id"] = nullptr;
        e["started_at"] = started_at;
        if (batch[i].ended && to_iso(batch[i].ended_ms, ended_at, sizeof(ended_at))) e["ended_at"] = ended_at;
        else                                                                         e["ended_at"] = nullptr;
        e["noise_db"]     = nullptr;  // filled in once the noise module exists
        e["motion_score"] = nullptr;  // filled in once the motion module exists
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
    } else if (code != -100) {
        Serial.printf("[event_log] send failed (%d), %d event(s) kept for later\n", code, n);
    }
}
