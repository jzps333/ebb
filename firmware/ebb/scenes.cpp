#include <Arduino.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include "scenes.h"
#include "media.h"
#include "net.h"

static const uint32_t SYNC_EVERY_MS = 5UL * 60 * 1000;
static const int      MAX_SCENES    = 6;

static Scene        set[MAX_SCENES];
static int          set_count = 0;
static portMUX_TYPE set_mux = portMUX_INITIALIZER_UNLOCKED;

// Parses {"scenes":[{"id","video","sound"},...]} into out; returns the count.
static int parse(const String &json, Scene *out)
{
    JsonDocument doc;
    if (deserializeJson(doc, json)) return -1;
    int n = 0;
    for (JsonObject s : doc["scenes"].as<JsonArray>()) {
        if (n == MAX_SCENES) break;
        strlcpy(out[n].id, s["id"] | "", sizeof(out[n].id));
        strlcpy(out[n].video, s["video"] | "", sizeof(out[n].video));
        strlcpy(out[n].sound, s["sound"] | "none", sizeof(out[n].sound));
        if (out[n].id[0] && out[n].video[0]) n++;
    }
    return n;
}

static void publish(const Scene *scenes, int n)
{
    taskENTER_CRITICAL(&set_mux);
    for (int i = 0; i < n; i++) set[i] = scenes[i];
    set_count = n;
    taskEXIT_CRITICAL(&set_mux);
}

void scenes_begin()
{
    Preferences prefs;
    prefs.begin("ebb", true);
    String json = prefs.getString("scenes", "");
    prefs.end();
    Scene loaded[MAX_SCENES];
    int n = json.isEmpty() ? 0 : parse(json, loaded);
    if (n > 0) publish(loaded, n);
    Serial.printf("[scenes] %d scene(s) saved on the watch\n", n > 0 ? n : 0);
}

void scenes_sync()
{
    static uint32_t last = 0;
    static bool first = true;
    if (!first && millis() - last < SYNC_EVERY_MS) return;
    if (!net_has_token()) return;

    String body;
    int code = net_get("/device-api/scenes", body);
    if (code == -100 || code == -102) return;  // WiFi / clock not ready yet
    first = false;
    last = millis();
    if (code != 200) {
        Serial.printf("[scenes] fetch failed: %d\n", code);
        return;
    }

    Scene fresh[MAX_SCENES];
    int n = parse(body, fresh);
    if (n < 0) return;

    // Download everything the set needs before switching to it.
    char path[40];
    for (int i = 0; i < n; i++) {
        snprintf(path, sizeof(path), "/video/%s.gif", fresh[i].video);
        media_ensure(path);
        if (strcmp(fresh[i].sound, "none") != 0) {
            snprintf(path, sizeof(path), "/audio/%s.mp3", fresh[i].sound);
            media_ensure(path);
        }
    }

    Preferences prefs;
    prefs.begin("ebb", false);
    if (prefs.getString("scenes", "") != body) {
        prefs.putString("scenes", body);
        prefs.putInt("scene_idx", 0);  // new week: start from the first scene
        Serial.printf("[scenes] new set of %d scene(s)\n", n);
    }
    prefs.end();
    publish(fresh, n);
}

bool scenes_next(Scene &out)
{
    taskENTER_CRITICAL(&set_mux);
    int n = set_count;
    taskEXIT_CRITICAL(&set_mux);
    if (n == 0) return false;

    Preferences prefs;
    prefs.begin("ebb", false);
    int idx = prefs.getInt("scene_idx", 0) % n;
    prefs.putInt("scene_idx", (idx + 1) % n);  // remembered across restarts
    prefs.end();

    taskENTER_CRITICAL(&set_mux);
    out = set[idx];
    taskEXIT_CRITICAL(&set_mux);
    return true;
}

bool scenes_find(const char *id, Scene &out)
{
    bool found = false;
    taskENTER_CRITICAL(&set_mux);
    for (int i = 0; i < set_count && !found; i++) {
        if (strcmp(set[i].id, id) == 0) {
            out = set[i];
            found = true;
        }
    }
    taskEXIT_CRITICAL(&set_mux);
    return found;
}
