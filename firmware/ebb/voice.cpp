#include <Arduino.h>
#include <ArduinoJson.h>
#include <FFat.h>
#include "voice.h"
#include "net.h"

static const uint32_t SYNC_EVERY_MS = 5UL * 60 * 1000;
static const int      MAX_CLIPS     = 8;

// Clip ids present in flash. Written by the network task, read by the main loop.
static char         clips[MAX_CLIPS][40];
static int          clip_count = 0;
static int          next_index = 0;
static portMUX_TYPE clips_mux = portMUX_INITIALIZER_UNLOCKED;

static void clip_path(const char *id, char *out, size_t len)
{
    snprintf(out, len, "/voice/%s.mp3", id);
}

static void publish(char ids[][40], int n)
{
    taskENTER_CRITICAL(&clips_mux);
    for (int i = 0; i < n; i++) strlcpy(clips[i], ids[i], sizeof(clips[i]));
    clip_count = n;
    if (next_index >= n) next_index = 0;
    taskEXIT_CRITICAL(&clips_mux);
}

void voice_begin()
{
    char ids[MAX_CLIPS][40];
    int n = 0;
    File dir = FFat.open("/voice");
    if (dir) {
        for (File f = dir.openNextFile(); f && n < MAX_CLIPS; f = dir.openNextFile()) {
            String name = String(f.name());
            f.close();
            if (!name.endsWith(".mp3") || name.endsWith(".part")) continue;
            name.remove(name.length() - 4);
            if (name.length() < sizeof(ids[0])) strlcpy(ids[n++], name.c_str(), sizeof(ids[0]));
        }
    }
    publish(ids, n);
}

void voice_sync()
{
    static uint32_t last = 0;
    static bool first = true;
    if (!first && millis() - last < SYNC_EVERY_MS) return;
    if (!net_has_token()) return;

    String body;
    int code = net_get("/device-api/voice", body);
    if (code == -100 || code == -102) return;  // WiFi / clock not ready: try next cycle
    first = false;
    last = millis();
    if (code != 200) {
        Serial.printf("[voice] list failed: %d\n", code);
        return;
    }

    JsonDocument doc;
    if (deserializeJson(doc, body)) return;
    FFat.mkdir("/voice");

    char keep[MAX_CLIPS][40];
    int n = 0;
    char path[64];
    for (JsonObject c : doc["clips"].as<JsonArray>()) {
        if (n == MAX_CLIPS) break;
        const char *id = c["id"] | "";
        const char *url = c["url"] | "";
        if (!id[0] || !url[0] || strlen(id) >= sizeof(keep[0])) continue;
        clip_path(id, path, sizeof(path));
        if (!FFat.exists(path)) {
            int dl = net_download(String(url), path);
            Serial.printf("[voice] %s %s\n", dl == 200 ? "saved" : "failed", path);
            if (dl != 200) continue;
        }
        strlcpy(keep[n++], id, sizeof(keep[0]));
    }

    // Remove clips the parent deleted or replaced.
    File dir = FFat.open("/voice");
    for (File f = dir.openNextFile(); f; f = dir.openNextFile()) {
        String name = String(f.name());  // "<id>.mp3"
        f.close();
        bool wanted = false;
        for (int i = 0; i < n; i++) wanted |= name == String(keep[i]) + ".mp3";
        if (!wanted) FFat.remove(String("/voice/") + name);
    }
    publish(keep, n);
    Serial.printf("[voice] %d approved clip(s) on the watch\n", n);
}

bool voice_next_clip(char *path_out, size_t len)
{
    char id[40];
    taskENTER_CRITICAL(&clips_mux);
    bool any = clip_count > 0;
    if (any) {
        strlcpy(id, clips[next_index], sizeof(id));
        next_index = (next_index + 1) % clip_count;
    }
    taskEXIT_CRITICAL(&clips_mux);
    if (any) clip_path(id, path_out, len);
    return any;
}
