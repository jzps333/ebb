#include <Arduino.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include "pairing.h"
#include "net.h"
#include "secrets.h"

// ---- What the network task tells the screen ---------------------------------
// Written by the network task, read by the main loop, so access goes through
// the critical section. `version` bumps on every change so the UI knows to redraw.

enum PairUi : uint8_t { UI_HIDDEN, UI_CONNECTING, UI_CODE, UI_PAIRED, UI_FINISHED };

struct PairShared {
    PairUi   ui;
    char     code[24];       // 20-char random code from pair/start
    char     nickname[41];
    int      teachers;
    uint32_t window_end_ms;  // millis() when the code stops working
    uint32_t version;
};

static PairShared   shared = { UI_HIDDEN, "", "", 0, 0, 0 };
static portMUX_TYPE shared_mux = portMUX_INITIALIZER_UNLOCKED;

static void publish(PairUi ui, const char *code, const char *nickname, int teachers, uint32_t window_end_ms)
{
    taskENTER_CRITICAL(&shared_mux);
    shared.ui = ui;
    if (code)     strlcpy(shared.code, code, sizeof(shared.code));
    if (nickname) strlcpy(shared.nickname, nickname, sizeof(shared.nickname));
    if (teachers >= 0) shared.teachers = teachers;
    if (window_end_ms) shared.window_end_ms = window_end_ms;
    shared.version++;
    taskEXIT_CRITICAL(&shared_mux);
}

static PairShared snapshot()
{
    taskENTER_CRITICAL(&shared_mux);
    PairShared copy = shared;
    taskEXIT_CRITICAL(&shared_mux);
    return copy;
}

// ---- Token in flash ---------------------------------------------------------

static Preferences prefs;

static void save_token(const char *token)
{
    prefs.begin("ebb", false);
    prefs.putString("token", token);
    prefs.end();
}

// ---- Network task side ------------------------------------------------------

static char     secret[80]   = "";  // proves to pair/status that we are this watch
static uint32_t code_end_ms  = 0;   // when the current code expires
static bool     window_open  = false;
static volatile bool restart_requested = false;

static String hardware_id()
{
    char buf[17];
    snprintf(buf, sizeof(buf), "%012llx", (unsigned long long)ESP.getEfuseMac());
    return String(buf);
}

static void request_code()
{
    JsonDocument req;
    req["hardware_id"] = hardware_id();
    String body, response;
    serializeJson(req, body);

    int code = net_post("/device-api/pair/start", body, response);
    JsonDocument doc;
    if (code != 200 || deserializeJson(doc, response)) {
        Serial.printf("[pairing] pair/start failed: %d %s\n", code, response.c_str());
        return;
    }
    strlcpy(secret, doc["secret"] | "", sizeof(secret));
    code_end_ms = millis() + (uint32_t)(doc["expires_in"] | 900) * 1000;
    Serial.printf("[pairing] code %s\n", (const char *)(doc["code"] | ""));
    publish(UI_CODE, doc["code"] | "", nullptr, 0, code_end_ms);
}

// Asks pair/status. With want_token, a claimed session also returns our token.
static void check_status(bool want_token)
{
    JsonDocument req;
    req["secret"] = secret;
    req["want_token"] = want_token;
    String body, response;
    serializeJson(req, body);

    int code = net_post("/device-api/pair/status", body, response);
    JsonDocument doc;
    if (code != 200 || deserializeJson(doc, response)) {
        Serial.printf("[pairing] pair/status failed: %d\n", code);
        return;
    }

    const char *status = doc["status"] | "";
    uint32_t end_ms = millis() + (uint32_t)(doc["expires_in"] | 0) * 1000;

    if (strcmp(status, "expired") == 0) {
        secret[0] = '\0';  // get a fresh code next tick
        if (window_open) {
            window_open = false;
            publish(UI_FINISHED, nullptr, nullptr, -1, 0);
        }
        return;
    }
    if (strcmp(status, "paired") != 0) return;  // still waiting for the parent

    const char *token = doc["token"] | "";
    if (want_token && token[0]) {
        save_token(token);
        net_set_token(token);
        window_open = true;
        Serial.printf("[pairing] paired with %s, token saved\n", (const char *)(doc["nickname"] | ""));
    }
    publish(UI_PAIRED, nullptr, doc["nickname"] | "", doc["teachers"] | 0, end_ms);
}

void pairing_network_tick()
{
    if (restart_requested) {
        restart_requested = false;
        secret[0] = '\0';
        window_open = false;
    }
    if (!net_connected()) return;

    if (!net_has_token()) {
        if (!secret[0] || (int32_t)(millis() - code_end_ms) > 0) request_code();
        else check_status(true);
    } else if (window_open) {
        if ((int32_t)(millis() - code_end_ms) > 0) {
            window_open = false;
            publish(UI_FINISHED, nullptr, nullptr, -1, 0);
        } else {
            check_status(false);  // keep the teacher count fresh
        }
    }
}

// ---- Main loop side: the pairing screen ---------------------------------------

static lv_obj_t *home = NULL;
static lv_obj_t *pair_scr = NULL;
static lv_obj_t *qr = NULL;
static lv_obj_t *code_label = NULL;
static lv_obj_t *info_label = NULL;
static lv_obj_t *done_btn = NULL;
static uint32_t  shown_version = 0;

static void close_pairing_screen()
{
    if (pair_scr && lv_scr_act() == pair_scr) lv_scr_load(home);
}

static void done_cb(lv_event_t *e)
{
    publish(UI_FINISHED, nullptr, nullptr, -1, 0);
}

static void build_pairing_screen()
{
    pair_scr = lv_obj_create(NULL);
    lv_obj_set_style_bg_color(pair_scr, lv_color_black(), 0);
    lv_obj_clear_flag(pair_scr, LV_OBJ_FLAG_SCROLLABLE);

    qr = lv_qrcode_create(pair_scr, 120, lv_color_black(), lv_color_white());
    lv_obj_set_style_border_color(qr, lv_color_white(), 0);
    lv_obj_set_style_border_width(qr, 6, 0);  // quiet zone so phones can read it
    lv_obj_align(qr, LV_ALIGN_TOP_MID, 0, 8);

    code_label = lv_label_create(pair_scr);
    lv_obj_set_style_text_color(code_label, lv_color_white(), 0);
    lv_obj_set_style_text_font(code_label, &lv_font_montserrat_20, 0);
    lv_obj_align(code_label, LV_ALIGN_TOP_MID, 0, 142);
    lv_label_set_text(code_label, "Pair with Ebb");

    info_label = lv_label_create(pair_scr);
    lv_obj_set_style_text_color(info_label, lv_color_white(), 0);
    lv_obj_set_style_text_font(info_label, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_align(info_label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_width(info_label, 230);
    lv_obj_align(info_label, LV_ALIGN_TOP_MID, 0, 172);

    done_btn = lv_btn_create(pair_scr);
    lv_obj_set_size(done_btn, 80, 30);
    lv_obj_align(done_btn, LV_ALIGN_BOTTOM_RIGHT, -6, -4);
    lv_obj_add_event_cb(done_btn, done_cb, LV_EVENT_CLICKED, NULL);
    lv_obj_t *l = lv_label_create(done_btn);
    lv_label_set_text(l, "Done");
    lv_obj_center(l);
    lv_obj_add_flag(done_btn, LV_OBJ_FLAG_HIDDEN);
}

static void show_screen()
{
    if (!pair_scr) build_pairing_screen();
    if (lv_scr_act() != pair_scr) lv_scr_load(pair_scr);
}

void pairing_begin(lv_obj_t *home_scr)
{
    home = home_scr;

    prefs.begin("ebb", true);
    String token = prefs.getString("token", "");
    prefs.end();

#ifdef DEVICE_TOKEN
    // Developer override: a token pasted into secrets.h skips pairing.
    if (token.isEmpty() && strlen(DEVICE_TOKEN) > 0) token = DEVICE_TOKEN;
#endif

    if (!token.isEmpty()) {
        net_set_token(token.c_str());
        Serial.println("[pairing] using saved device token");
        return;
    }
    Serial.println("[pairing] no device token: showing pairing screen");
    publish(UI_CONNECTING, "", nullptr, 0, 0);
}

void pairing_forget()
{
    prefs.begin("ebb", false);
    prefs.remove("token");
    prefs.end();
    net_set_token("");
    restart_requested = true;
    publish(UI_CONNECTING, "", nullptr, 0, 0);
    Serial.println("[pairing] token erased; pairing again");
}

void pairing_ui_update()
{
    static uint32_t last_tick = 0;
    PairShared s = snapshot();
    bool changed = s.version != shown_version;
    bool second_passed = millis() - last_tick >= 1000;
    if (!changed && !second_passed) return;
    last_tick = millis();
    shown_version = s.version;

    if (s.ui == UI_HIDDEN) return;
    if (s.ui == UI_FINISHED) {
        close_pairing_screen();
        return;
    }

    // Only switch screens on a real change, so calm mode is never yanked away.
    if (changed) show_screen();
    if (!pair_scr) return;

    uint32_t left_s = (int32_t)(s.window_end_ms - millis()) > 0 ? (s.window_end_ms - millis()) / 1000 : 0;

    if (s.ui == UI_CONNECTING) {
        lv_obj_add_flag(qr, LV_OBJ_FLAG_HIDDEN);
        lv_label_set_text(info_label, "Connecting...");
        return;
    }
    // The code is only ever scanned, never shown as text: it is long and random
    // so nobody can guess it.
    if (changed && s.code[0]) {
        lv_qrcode_update(qr, s.code, strlen(s.code));
        lv_obj_clear_flag(qr, LV_OBJ_FLAG_HIDDEN);
    }
    if (s.ui == UI_CODE) {
        lv_obj_add_flag(done_btn, LV_OBJ_FLAG_HIDDEN);
        lv_label_set_text_fmt(info_label, "Parent: scan in the Ebb app\n%lu:%02lu left",
                              (unsigned long)(left_s / 60), (unsigned long)(left_s % 60));
    } else if (s.ui == UI_PAIRED) {
        lv_obj_clear_flag(done_btn, LV_OBJ_FLAG_HIDDEN);
        lv_label_set_text_fmt(info_label, "Paired with %s\nTeacher: scan now (%d linked) %lu:%02lu",
                              s.nickname, s.teachers,
                              (unsigned long)(left_s / 60), (unsigned long)(left_s % 60));
    }
}
