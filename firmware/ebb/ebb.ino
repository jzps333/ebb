#include <LilyGoLib.h>
#include <LV_Helper.h>
#include <WiFi.h>
#include "config.h"
#include "calm_mode.h"
#include "commands.h"
#include "pairing.h"
#include "profile_store.h"
#include "audio_player.h"
#include "voice.h"

// Temporary home screen until the ui module exists: a Start button, and
// Serial shortcuts 's' / 'x' for start/stop. Connection details are on Serial.

// LVGL event callbacks must have this exact signature.
static void start_btn_cb(lv_event_t *e)
{
    start_calm();
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
    } else if (c == 'u') {
        pairing_forget();  // unpair: erase the token, show the QR again
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
    calm_mode_init();
    pairing_begin(lv_scr_act());  // before commands_begin: loads the device token
    commands_begin();

    Serial.printf("Ebb %s ready. Send 's' start calm, 'x' stop, 'u' unpair.\n", FIRMWARE_VERSION);
}

void loop()
{
    handle_serial();
    commands_handle();
    pairing_ui_update();
    lv_task_handler();
    delay(5);
}
