#include <LilyGoLib.h>
#include <LV_Helper.h>
#include <WiFi.h>
#include <FFat.h>
#include "config.h"
#include "net.h"
#include "calm_mode.h"
#include "commands.h"
#include "pairing.h"
#include "profile_store.h"
#include "audio_player.h"
#include "voice.h"
#include "scenes.h"
#include "settings.h"
#include "motion.h"
#include "noise.h"
#include "agitation.h"
#include "gps.h"

// Temporary home screen until the ui module exists: a Start button, and
// Serial shortcuts 's' / 'x' for start/stop. Connection details are on Serial.


// LVGL event callbacks must have this exact signature.
static void start_btn_cb(lv_event_t *e)
{
    start_calm();
}

// ---- Home screen ------------------------------------------------------------
// Dark and calm: the time, an agitation ring (green / amber / red by tier)
// around one big "Start calm" button, the current state and battery.

static lv_obj_t *time_label = NULL;
static lv_obj_t *state_label = NULL;
static lv_obj_t *battery_label = NULL;
static lv_obj_t *ring = NULL;

static lv_obj_t *small_label(lv_obj_t *parent, const lv_font_t *font, uint32_t color)
{
    lv_obj_t *l = lv_label_create(parent);
    lv_obj_set_style_text_font(l, font, 0);
    lv_obj_set_style_text_color(l, lv_color_hex(color), 0);
    return l;
}

static void build_home_screen()
{
    lv_obj_t *scr = lv_scr_act();
    lv_obj_set_style_bg_color(scr, lv_color_hex(0x0B1A2A), 0);
    lv_obj_set_style_bg_grad_color(scr, lv_color_hex(0x05202A), 0);
    lv_obj_set_style_bg_grad_dir(scr, LV_GRAD_DIR_VER, 0);
    lv_obj_clear_flag(scr, LV_OBJ_FLAG_SCROLLABLE);

    lv_obj_t *brand = small_label(scr, &lv_font_montserrat_16, 0x52A0B3);
    lv_label_set_text(brand, "ebb");
    lv_obj_align(brand, LV_ALIGN_TOP_LEFT, 14, 8);

    battery_label = small_label(scr, &lv_font_montserrat_14, 0x9FB3BC);
    lv_label_set_text(battery_label, "");
    lv_obj_align(battery_label, LV_ALIGN_TOP_RIGHT, -14, 10);

    time_label = small_label(scr, &lv_font_montserrat_40, 0xEAF2EE);
    lv_label_set_text(time_label, "--:--");
    lv_obj_align(time_label, LV_ALIGN_TOP_MID, 0, 22);

    state_label = small_label(scr, &lv_font_montserrat_14, 0x6CC070);
    lv_label_set_text(state_label, "Settled");
    lv_obj_align(state_label, LV_ALIGN_TOP_MID, 0, 68);

    // Agitation ring: 0 to 1.5, full at 1.5 (1.0 is the auto-start line).
    ring = lv_arc_create(scr);
    lv_obj_set_size(ring, 146, 146);
    lv_arc_set_rotation(ring, 135);
    lv_arc_set_bg_angles(ring, 0, 270);
    lv_arc_set_range(ring, 0, 150);
    lv_arc_set_value(ring, 0);
    lv_obj_remove_style(ring, NULL, LV_PART_KNOB);
    lv_obj_clear_flag(ring, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_set_style_arc_width(ring, 10, LV_PART_MAIN);
    lv_obj_set_style_arc_width(ring, 10, LV_PART_INDICATOR);
    lv_obj_set_style_arc_color(ring, lv_color_hex(0x1E3442), LV_PART_MAIN);
    lv_obj_set_style_arc_color(ring, lv_color_hex(0x6CC070), LV_PART_INDICATOR);
    lv_obj_align(ring, LV_ALIGN_BOTTOM_MID, 0, -6);

    lv_obj_t *btn = lv_btn_create(scr);
    lv_obj_set_size(btn, 104, 104);
    lv_obj_set_style_radius(btn, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(btn, lv_color_hex(0x21657A), 0);
    lv_obj_set_style_bg_grad_color(btn, lv_color_hex(0x194C60), 0);
    lv_obj_set_style_bg_grad_dir(btn, LV_GRAD_DIR_VER, 0);
    lv_obj_set_style_shadow_width(btn, 0, 0);
    lv_obj_align_to(btn, ring, LV_ALIGN_CENTER, 0, 0);
    lv_obj_add_event_cb(btn, start_btn_cb, LV_EVENT_CLICKED, NULL);
    lv_obj_t *btn_label = small_label(btn, &lv_font_montserrat_20, 0xFFFFFF);
    lv_label_set_text(btn_label, "Start\ncalm");
    lv_obj_set_style_text_align(btn_label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_center(btn_label);
}

// New York local time from the UTC clock: EDT from the 2nd Sunday of March
// (07:00 UTC) to the 1st Sunday of November (06:00 UTC), else EST.
static int nth_sunday(int year, int month, int n)
{
    struct tm t = {};
    t.tm_year = year - 1900;
    t.tm_mon = month;
    t.tm_mday = 1;
    t.tm_hour = 12;
    time_t first = mktime(&t);  // the watch's TZ is UTC
    struct tm f;
    gmtime_r(&first, &f);
    return 1 + (7 - f.tm_wday) % 7 + 7 * (n - 1);
}

static bool ny_time(char *out, size_t len)
{
    if (!net_clock_ok()) return false;  // RTC chip time can be hours off until NTP
    time_t now = time(nullptr);
    struct tm u;
    gmtime_r(&now, &u);
    int y = u.tm_year + 1900;
    struct tm a = {}, b = {};
    a.tm_year = b.tm_year = y - 1900;
    a.tm_mon = 2;  a.tm_mday = nth_sunday(y, 2, 2);  a.tm_hour = 7;
    b.tm_mon = 10; b.tm_mday = nth_sunday(y, 10, 1); b.tm_hour = 6;
    bool dst = now >= mktime(&a) && now < mktime(&b);
    time_t local = now - (dst ? 4 : 5) * 3600;
    struct tm l;
    gmtime_r(&local, &l);
    int h = l.tm_hour % 12;
    snprintf(out, len, "%d:%02d", h ? h : 12, l.tm_min);
    return true;
}

// Twice a second: ring, state and time; battery every 30 s (I2C, main loop).
static void update_home()
{
    static uint32_t last = 0, last_batt = 0;
    if (!ring || millis() - last < 500) return;
    last = millis();

    int tier = agitation_tier();
    float a = agitation_level();
    uint32_t color = tier >= 2 ? 0xE05050 : (tier == 1 || a >= 0.6f) ? 0xF0A060 : 0x6CC070;
    lv_arc_set_value(ring, (int16_t)((a > 1.5f ? 1.5f : a) * 100));
    lv_obj_set_style_arc_color(ring, lv_color_hex(color), LV_PART_INDICATOR);
    const char *state = tier >= 3 ? "Getting an adult" : tier == 2 ? "Calm mode" :
                        (tier == 1 || a >= 0.6f) ? "Take a slow breath" : "Settled";
    lv_label_set_text(state_label, state);
    lv_obj_set_style_text_color(state_label, lv_color_hex(color), 0);

    char t[8];
    if (ny_time(t, sizeof(t))) lv_label_set_text(time_label, t);

    if (last_batt == 0 || millis() - last_batt > 30000) {
        last_batt = millis();
        if (watch.isBatteryConnect()) lv_label_set_text_fmt(battery_label, "%d%%", watch.getBatteryPercent());
    }
}

static void handle_serial()
{
    if (!Serial.available()) return;
    char c = Serial.read();
    if (c == 's') {
        Serial.println("start_calm()");
        start_calm();
    } else if (c == 'x') {
        Serial.println("stop_calm()");
        stop_calm();
    } else if (c == 'v') {  // speaker test (the home screen has no Test sound button now)
        char path[64];
        if (voice_next_clip(path, sizeof(path))) audio_play_once(path, MAX_GAIN);  // speaker test
        else Serial.println("no voice clips on the watch");
    } else if (c == 'u') {
        pairing_forget();             // unpair: erase the token, show the QR again
        agitation_reset_baseline();   // the next child has their own normal
    } else if (c == 'a') {
        agitation_print();            // live motion / noise / z / agitation / tier
    } else if (c == 'g') {
        agitation_simulate(20000);    // demo: high motion agitation for 20 s -> auto-start
    }
}

void setup()
{
    Serial.begin(115200);
    watch.begin();
    watch.setRotation(SCREEN_ROTATION);
    beginLvglHelper();

    build_home_screen();
    profile_store_begin();
    audio_begin();
    voice_begin();
    scenes_begin();
    settings_begin();
    motion_begin();
    noise_begin();
    gps_begin();
    calm_mode_init();
    agitation_begin();  // after calm_mode_init: makes an LVGL timer
    pairing_begin(lv_scr_act());  // before commands_begin: loads the device token
    commands_begin();

    Serial.printf("Ebb %s ready. Send 's' start calm, 'x' stop, 'v' voice test, 'u' unpair, 'a' agitation, 'g' simulate agitation.\n", FIRMWARE_VERSION);
}

void loop()
{
    handle_serial();
    commands_handle();
    motion_update();     // accelerometer at 25 Hz (I2C: main loop only)
    gps_update();
    agitation_update();  // 5 Hz: tiers, haptic cue, auto-start, samples
    update_home();
    pairing_ui_update();
    lv_task_handler();
    delay(5);
}
