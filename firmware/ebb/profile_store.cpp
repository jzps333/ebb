#include <ArduinoJson.h>
#include <Preferences.h>
#include "profile_store.h"

static CalmProfile  current;
static portMUX_TYPE current_mux = portMUX_INITIALIZER_UNLOCKED;

static CalmProfile defaults()
{
    CalmProfile p = {};
    p.version = 0;
    strlcpy(p.theme, "ocean", sizeof(p.theme));
    strlcpy(p.colors[0], "blue", sizeof(p.colors[0]));
    strlcpy(p.breath_pattern, "slow_4_6", sizeof(p.breath_pattern));
    strlcpy(p.vibration, "gentle", sizeof(p.vibration));
    strlcpy(p.sound, "none", sizeof(p.sound));
    strlcpy(p.volume, "off", sizeof(p.volume));
    strlcpy(p.calm_message, "You're safe. Breathe with me.", sizeof(p.calm_message));
    return p;
}

// Copies the fields we use. Unknown or missing values keep the defaults,
// so a bad profile can never stop calm mode from working.
static bool parse(const String &json, CalmProfile &out)
{
    JsonDocument doc;
    if (deserializeJson(doc, json)) return false;
    out = defaults();
    out.version = doc["version"] | 0;
    strlcpy(out.theme, doc["theme"] | out.theme, sizeof(out.theme));
    strlcpy(out.colors[0], doc["colors"][0] | out.colors[0], sizeof(out.colors[0]));
    strlcpy(out.colors[1], doc["colors"][1] | "", sizeof(out.colors[1]));
    strlcpy(out.breath_pattern, doc["breath_pattern"] | out.breath_pattern, sizeof(out.breath_pattern));
    strlcpy(out.vibration, doc["vibration"] | out.vibration, sizeof(out.vibration));
    strlcpy(out.sound, doc["sound"] | out.sound, sizeof(out.sound));
    strlcpy(out.volume, doc["volume"] | out.volume, sizeof(out.volume));
    strlcpy(out.calm_message, doc["calm_message"] | out.calm_message, sizeof(out.calm_message));
    return out.version > 0;
}

void profile_store_begin()
{
    Preferences prefs;
    prefs.begin("ebb", true);
    String json = prefs.getString("profile", "");
    prefs.end();

    CalmProfile p;
    if (json.isEmpty() || !parse(json, p)) p = defaults();
    taskENTER_CRITICAL(&current_mux);
    current = p;
    taskEXIT_CRITICAL(&current_mux);
    Serial.printf("[profile] v%d theme=%s sound=%s breath=%s\n", p.version, p.theme, p.sound, p.breath_pattern);
}

CalmProfile profile_store_get()
{
    taskENTER_CRITICAL(&current_mux);
    CalmProfile copy = current;
    taskEXIT_CRITICAL(&current_mux);
    return copy;
}

int profile_store_version()
{
    return profile_store_get().version;
}

bool profile_store_save_json(const String &json)
{
    CalmProfile p;
    if (!parse(json, p) || p.version <= profile_store_version()) return false;

    Preferences prefs;
    prefs.begin("ebb", false);
    prefs.putString("profile", json);
    prefs.end();

    taskENTER_CRITICAL(&current_mux);
    current = p;
    taskEXIT_CRITICAL(&current_mux);
    Serial.printf("[profile] saved v%d theme=%s sound=%s breath=%s\n", p.version, p.theme, p.sound, p.breath_pattern);
    return true;
}

uint32_t profile_color_hex(const char *name)
{
    if (!strcmp(name, "blue"))   return 0x3FA7D6;
    if (!strcmp(name, "teal"))   return 0x2BB3A3;
    if (!strcmp(name, "green"))  return 0x6CC070;
    if (!strcmp(name, "purple")) return 0x9B7FD4;
    if (!strcmp(name, "pink"))   return 0xE88AB8;
    if (!strcmp(name, "yellow")) return 0xF2CF5B;
    if (!strcmp(name, "orange")) return 0xF0A060;
    return 0x3FA7D6;
}
