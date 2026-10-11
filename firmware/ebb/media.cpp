#include <Arduino.h>
#include <FFat.h>
#include "media.h"
#include "net.h"
#include "profile_store.h"
#include "secrets.h"
#include <Preferences.h>

// Bump when the scene files in the bucket are replaced (same names, new
// content): the watch then deletes its copies and downloads them again.
// 2: space/shapes re-encoded with ffmpeg (Pillow's GIFs drew a see-through shape).
// 3: space is real footage (Earth spinning); the drawn starfield still showed it.
static const int MEDIA_REV = 3;

static void remove_all(const char *dir)
{
    File d = FFat.open(dir);
    if (!d) return;
    for (File f = d.openNextFile(); f; f = d.openNextFile()) {
        String path = String(dir) + "/" + f.name();
        f.close();
        FFat.remove(path);
    }
}

// Once per boot: if the media revision changed, start from empty.
static void check_revision()
{
    static bool checked = false;
    if (checked) return;
    checked = true;
    Preferences prefs;
    prefs.begin("ebb", false);
    if (prefs.getInt("media_rev", 0) != MEDIA_REV) {
        remove_all("/video");
        remove_all("/audio");
        prefs.putInt("media_rev", MEDIA_REV);
        Serial.printf("[media] new media revision %d: re-downloading scenes\n", MEDIA_REV);
    }
    prefs.end();
}

bool media_has(const char *path)
{
    return FFat.exists(path);
}

// Public object URL for a flash path, derived from API_BASE_URL
// (https://<ref>.supabase.co/functions/v1 -> .../storage/v1/object/public/scene-media).
// Files sit at the top of the bucket (ocean.gif, rain.mp3), so only the file
// name is used; the extension keeps ocean.gif and ocean.mp3 apart.
static String media_url(const char *path)
{
    String base = String(API_BASE_URL);
    base.replace("/functions/v1", "/storage/v1/object/public/scene-media");
    const char *name = strrchr(path, '/');
    return base + (name ? name : path);
}

static void ensure(const char *path)
{
    if (media_has(path)) return;
    Serial.printf("[media] downloading %s\n", path);
    int code = net_download(media_url(path), path);
    if (code == 200) Serial.printf("[media] saved %s (%u bytes)\n", path, (unsigned)FFat.open(path).size());
    else Serial.printf("[media] %s failed: %d\n", path, code);
}

void media_sync()
{
    static uint32_t last_try = 0;
    if (millis() - last_try < 15000 && last_try != 0) return;  // don't hammer on failures
    last_try = millis();

    check_revision();
    CalmProfile p = profile_store_get();
    char path[40];

    FFat.mkdir("/video");
    FFat.mkdir("/audio");

    snprintf(path, sizeof(path), "/video/%s.gif", p.theme);
    ensure(path);

    if (strcmp(p.sound, "none") != 0 && strcmp(p.volume, "off") != 0) {
        snprintf(path, sizeof(path), "/audio/%s.mp3", p.sound);
        ensure(path);
    }
}
