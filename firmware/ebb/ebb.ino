#include <LilyGoLib.h>
#include <LV_Helper.h>
#include <WiFi.h>
#include "config.h"
#include "calm_mode.h"
#include "commands.h"
#include "pairing.h"
#include "profile_store.h"
#include "audio_player.h"

// Temporary home screen until the ui module exists: a Start button, a status
// line for WiFi/polling, and Serial shortcuts 's' / 'x' for start/stop.

static lv_obj_t *status_label = NULL;

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

    status_label = lv_label_create(scr);
    lv_obj_set_style_text_font(status_label, &lv_font_montserrat_14, 0);
    lv_obj_align(status_label, LV_ALIGN_BOTTOM_MID, 0, -10);
    lv_label_set_text(status_label, "WiFi: connecting...");
}

// Runs on the main loop (same task as LVGL), so it may touch labels safely.
static void update_status_label()
{
    static uint32_t last = 0;
    if (millis() - last < 500) return;
    last = millis();

    if (WiFi.status() != WL_CONNECTED) {
        lv_label_set_text(status_label, "WiFi: connecting...");
        return;
    }
    int code = commands_last_http_code();
    uint32_t ago = (millis() - commands_last_poll_ms()) / 1000;
    if (code == 0) {
        lv_label_set_text_fmt(status_label, "%s  poll: waiting", WiFi.localIP().toString().c_str());
    } else {
        lv_label_set_text_fmt(status_label, "%s  poll: %d (%lus ago)",
                              WiFi.localIP().toString().c_str(), code, (unsigned long)ago);
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
    update_status_label();
    lv_task_handler();
    delay(5);
}
