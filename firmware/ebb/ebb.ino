#include <LilyGoLib.h>
#include <LV_Helper.h>
#include <WiFi.h>
#include <FFat.h>
#include "config.h"
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

static lv_obj_t *agitation_bar = NULL;  // thin bar along the bottom: length = agitation, colour = tier

// LVGL event callbacks must have this exact signature.
static void start_btn_cb(lv_event_t *e)
{
    start_calm();
}

static void test_sound_cb(lv_event_t *e)
{
    char path[64];
    if (voice_next_clip(path, sizeof(path))) audio_play_once(path, MAX_GAIN);
    else if (FFat.exists("/audio/rain.mp3")) audio_play_once("/audio/rain.mp3", MAX_GAIN);
    else Serial.println("[audio] test: no sounds on the watch yet");
}

static void build_home_screen()
{
    lv_obj_t *scr = lv_scr_act();

    lv_obj_t *title = lv_label_create(scr);
    lv_label_set_text(title, "Ebb");
    lv_obj_set_style_text_font(title, &lv_font_montserrat_24, 0);
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 30);

    lv_obj_t *btn = lv_btn_create(scr);
    lv_obj_set_size(btn, 150, 60);
    lv_obj_center(btn);
    lv_obj_add_event_cb(btn, start_btn_cb, LV_EVENT_CLICKED, NULL);

    lv_obj_t *btn_label = lv_label_create(btn);
    lv_label_set_text(btn_label, "Start calm");
    lv_obj_center(btn_label);

    // Plays a voice clip at maximum volume, to check the speaker.
    lv_obj_t *test = lv_btn_create(scr);
    lv_obj_set_size(test, 150, 44);
    lv_obj_align(test, LV_ALIGN_CENTER, 0, 62);
    lv_obj_set_style_bg_color(test, lv_color_hex(0x444444), 0);
    lv_obj_add_event_cb(test, test_sound_cb, LV_EVENT_CLICKED, NULL);
    lv_obj_t *test_label = lv_label_create(test);
    lv_label_set_text(test_label, "Test sound");
    lv_obj_center(test_label);

    agitation_bar = lv_obj_create(scr);
    lv_obj_set_size(agitation_bar, 8, 6);
    lv_obj_set_style_radius(agitation_bar, 3, 0);
    lv_obj_set_style_border_width(agitation_bar, 0, 0);
    lv_obj_clear_flag(agitation_bar, LV_OBJ_FLAG_CLICKABLE | LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_align(agitation_bar, LV_ALIGN_BOTTOM_MID, 0, -10);
}

// Green settled, amber rising, red calm/adult. Twice a second is plenty.
static void update_agitation_bar()
{
    static uint32_t last = 0;
    if (!agitation_bar || millis() - last < 500) return;
    last = millis();
    int tier = agitation_tier();
    uint32_t color = tier == 0 ? 0x6CC070 : (tier == 1 ? 0xF0A060 : 0xE05050);
    float a = agitation_level();
    if (a > 1.5f) a = 1.5f;
    lv_obj_set_width(agitation_bar, 8 + (lv_coord_t)(a / 1.5f * 192));
    lv_obj_set_style_bg_color(agitation_bar, lv_color_hex(color), 0);
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
    } else if (c == 'v') {
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
    update_agitation_bar();
    pairing_ui_update();
    lv_task_handler();
    delay(5);
}
