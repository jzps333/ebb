#include <Preferences.h>
#include "settings.h"

static const uint32_t MAGIC = 0xEBB5E701;  // bumps if the struct below changes

struct Saved {
    uint32_t         magic;
    AdaptiveSettings s;
};

// Same defaults as child_settings in the database: nothing automatic until
// the parent turns it on.
static AdaptiveSettings current = { false, false, 2.5f, 2.5f, false };
static char             scene_pick[24] = "";
static portMUX_TYPE     mux = portMUX_INITIALIZER_UNLOCKED;

static float clamp_k(float k)
{
    if (isnan(k)) return 2.5f;
    return k < 1.5f ? 1.5f : (k > 5.0f ? 5.0f : k);
}

void settings_begin()
{
    Preferences prefs;
    prefs.begin("ebb", true);
    Saved saved = {};
    size_t n = prefs.getBytes("adapt", &saved, sizeof(saved));
    prefs.end();
    if (n == sizeof(saved) && saved.magic == MAGIC) {
        taskENTER_CRITICAL(&mux);
        current = saved.s;
        taskEXIT_CRITICAL(&mux);
    }
    AdaptiveSettings s = settings_get();
    Serial.printf("[settings] auto_motion=%d auto_noise=%d motion_k=%.2f noise_k=%.2f gps=%d\n",
                  s.auto_motion, s.auto_noise, s.motion_k, s.noise_k, s.gps_enabled);
}

AdaptiveSettings settings_get()
{
    taskENTER_CRITICAL(&mux);
    AdaptiveSettings copy = current;
    taskEXIT_CRITICAL(&mux);
    return copy;
}

void settings_apply_poll(JsonVariantConst settings, JsonVariantConst pick)
{
    char p[sizeof(scene_pick)];
    strlcpy(p, pick | "", sizeof(p));
    taskENTER_CRITICAL(&mux);
    strlcpy(scene_pick, p, sizeof(scene_pick));
    taskEXIT_CRITICAL(&mux);

    if (!settings.is<JsonObjectConst>()) return;  // older device-api: keep what we have
    AdaptiveSettings old = settings_get();
    AdaptiveSettings s = old;
    s.auto_motion = settings["auto_motion"] | old.auto_motion;
    s.auto_noise  = settings["auto_noise"] | old.auto_noise;
    s.motion_k    = clamp_k(settings["motion_k"] | old.motion_k);
    s.noise_k     = clamp_k(settings["noise_k"] | old.noise_k);
    s.gps_enabled = settings["gps_enabled"] | old.gps_enabled;
    if (memcmp(&s, &old, sizeof(s)) == 0) return;  // unchanged: no flash write

    taskENTER_CRITICAL(&mux);
    current = s;
    taskEXIT_CRITICAL(&mux);

    Saved saved = { MAGIC, s };
    Preferences prefs;
    prefs.begin("ebb", false);
    prefs.putBytes("adapt", &saved, sizeof(saved));
    prefs.end();
    Serial.printf("[settings] now auto_motion=%d auto_noise=%d motion_k=%.2f noise_k=%.2f gps=%d\n",
                  s.auto_motion, s.auto_noise, s.motion_k, s.noise_k, s.gps_enabled);
}

bool settings_scene_pick(char *out, size_t len)
{
    taskENTER_CRITICAL(&mux);
    strlcpy(out, scene_pick, len);
    taskEXIT_CRITICAL(&mux);
    return out[0] != '\0';
}
