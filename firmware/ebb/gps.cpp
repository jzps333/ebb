#include <LilyGoLib.h>
#include <TinyGPSPlus.h>
#include <ArduinoJson.h>
#include "gps.h"
#include "net.h"
#include "config.h"
#include "settings.h"

static const float    UERE_M = 5.0f;          // metres per unit of HDOP, roughly
static const int      MAX_BYTES_PER_LOOP = 256;  // never hog the UI loop

static TinyGPSPlus parser;   // main loop only
static bool        present = false;

// Latest fix: written by the main loop, read by any task.
static GpsFix       latest = {};
static bool         has_latest = false;

// Trail points: main loop adds, network task sends.
static GpsFix       trail[GPS_QUEUE_SIZE];
static int          trail_count = 0;
static uint32_t     last_trail_ms = 0;
static bool         trail_started = false;

static portMUX_TYPE mux = portMUX_INITIALIZER_UNLOCKED;

void gps_begin()
{
    present = watch.getDeviceProbe() & WATCH_GPS_ONLINE;
    if (present) {
        // LilyGoLib opened the UART with the default 256-byte buffer, which
        // overflows (38400 baud) whenever the UI loop stalls for a GIF frame.
        GPSSerial.end();
        GPSSerial.setRxBufferSize(2048);
        GPSSerial.begin(38400, SERIAL_8N1, SHIELD_GPS_RX, SHIELD_GPS_TX);
    }
    Serial.printf("[gps] %s\n", present ? "GPS module found" : "no GPS module: location off");
}

static void queue_trail_point(const GpsFix &f)
{
    taskENTER_CRITICAL(&mux);
    if (trail_count == GPS_QUEUE_SIZE) {
        memmove(&trail[0], &trail[1], sizeof(GpsFix) * (GPS_QUEUE_SIZE - 1));  // keep the newest
        trail_count--;
    }
    trail[trail_count++] = f;
    taskEXIT_CRITICAL(&mux);
}

void gps_update()
{
    if (!present) return;
    if (!settings_get().gps_enabled) {
        // Opted out: forget everything we knew, keep the UART drained.
        taskENTER_CRITICAL(&mux);
        has_latest = false;
        trail_count = 0;
        taskEXIT_CRITICAL(&mux);
        trail_started = false;
        while (GPSSerial.available()) GPSSerial.read();
        return;
    }

    for (int i = 0; i < MAX_BYTES_PER_LOOP && GPSSerial.available(); i++) parser.encode(GPSSerial.read());
    if (!parser.location.isUpdated() || !parser.location.isValid()) return;

    GpsFix f;
    f.lat = parser.location.lat();
    f.lng = parser.location.lng();
    f.accuracy_m = parser.hdop.isValid() ? (float)parser.hdop.hdop() * UERE_M : 50.0f;
    f.at_ms = millis() - parser.location.age();
    taskENTER_CRITICAL(&mux);
    latest = f;
    has_latest = true;
    taskEXIT_CRITICAL(&mux);

    // First good fix goes on the trail straight away, then one every 5 min.
    if (!trail_started || millis() - last_trail_ms >= GPS_TRAIL_MS) {
        trail_started = true;
        last_trail_ms = millis();
        queue_trail_point(f);
    }
}

bool gps_latest(GpsFix &out)
{
    if (!present || !settings_get().gps_enabled) return false;
    taskENTER_CRITICAL(&mux);
    bool ok = has_latest;
    out = latest;
    taskEXIT_CRITICAL(&mux);
    return ok && millis() - out.at_ms <= GPS_FIX_MAX_AGE_MS;
}

void gps_flush()
{
    if (!present) return;
    GpsFix batch[GPS_QUEUE_SIZE];
    taskENTER_CRITICAL(&mux);
    int n = trail_count;
    memcpy(batch, trail, sizeof(GpsFix) * n);
    taskEXIT_CRITICAL(&mux);
    if (n == 0) return;

    // { "points": [ { "at": "…", "lat": 40.7, "lng": -74.0, "accuracy_m": 8 } ] }
    JsonDocument doc;
    JsonArray points = doc["points"].to<JsonArray>();
    char at[24];
    for (int i = 0; i < n; i++) {
        if (!net_iso_time(batch[i].at_ms, at, sizeof(at))) return;  // retry once the clock is set
        JsonObject p = points.add<JsonObject>();
        p["at"]         = at;
        p["lat"]        = serialized(String(batch[i].lat, 6));
        p["lng"]        = serialized(String(batch[i].lng, 6));
        p["accuracy_m"] = roundf(batch[i].accuracy_m * 10) / 10;
    }

    String body, response;
    serializeJson(doc, body);
    int code = net_post("/device-api/location", body, response);
    if (code == 200 || code == 204 || (code >= 400 && code < 500)) {
        // 204 = gps not enabled on the server: dropped there, drop here too.
        if (code >= 400) Serial.printf("[gps] location rejected %d: %s\n", code, response.c_str());
        taskENTER_CRITICAL(&mux);
        int sent = n < trail_count ? n : trail_count;
        memmove(&trail[0], &trail[sent], sizeof(GpsFix) * (trail_count - sent));
        trail_count -= sent;
        taskEXIT_CRITICAL(&mux);
    } else if (code != -100 && code != -102) {
        Serial.printf("[gps] send failed (%d), %d point(s) kept\n", code, n);
    }
}
