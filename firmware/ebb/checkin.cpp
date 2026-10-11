#include <Arduino.h>
#include "checkin.h"
#include "config.h"

// ---- Look -------------------------------------------------------------------
static const int32_t FACE_PX  = 68;    // three across a 240 px screen
static const int32_t EYE_PX   = 10;
static const int32_t MOUTH_PX = 34;

struct Face {
    const char *feeling;  // what goes on the event report
    const char *label;
    uint32_t    color;
    int8_t      mouth;    // +1 smile, 0 straight, -1 frown
};

static const Face FACES[3] = {
    {"better", "Better", 0x6CC070, +1},  // green
    {"same",   "Same",   0xF2CF5B, 0},   // yellow
    {"worse",  "Worse",  0x9B7FD4, -1},  // soft purple: "worse" is fine to say, not an alarm
};

// ---- State (main loop only) -------------------------------------------------
static lv_obj_t        *scr = NULL;
static lv_obj_t        *countdown = NULL;   // bar that empties over the 10 s
static lv_obj_t        *back_to = NULL;
static lv_timer_t      *timeout = NULL;
static checkin_done_cb  done_cb = NULL;
static bool             active = false;

static void finish(const char *feeling)
{
    if (!active) return;
    active = false;
    if (timeout) {
        lv_timer_del(timeout);
        timeout = NULL;
    }
    lv_anim_del(countdown, NULL);
    if (back_to) lv_scr_load(back_to);
    Serial.printf("[checkin] child_feeling = %s\n", feeling ? feeling : "(no answer)");
    checkin_done_cb cb = done_cb;
    done_cb = NULL;
    if (cb) cb(feeling);
}

static void face_clicked_cb(lv_event_t *e)
{
    finish((const char *)lv_event_get_user_data(e));
}

static void timeout_cb(lv_timer_t *t)
{
    finish(NULL);
}

static void bar_anim_cb(void *obj, int32_t v)
{
    lv_bar_set_value((lv_obj_t *)obj, v, LV_ANIM_OFF);
}

// A round button with two eyes and a mouth drawn from LVGL shapes.
static void make_face(lv_obj_t *parent, const Face &f, lv_coord_t x)
{
    lv_obj_t *btn = lv_btn_create(parent);
    lv_obj_set_size(btn, FACE_PX, FACE_PX);
    lv_obj_set_style_radius(btn, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(btn, lv_color_hex(f.color), 0);
    lv_obj_set_style_border_color(btn, lv_color_white(), 0);
    lv_obj_set_style_border_width(btn, 3, 0);
    lv_obj_set_style_border_width(btn, 6, LV_STATE_PRESSED);
    lv_obj_set_style_pad_all(btn, 0, 0);
    lv_obj_align(btn, LV_ALIGN_CENTER, x, -4);
    lv_obj_add_event_cb(btn, face_clicked_cb, LV_EVENT_CLICKED, (void *)f.feeling);

    for (int side = -1; side <= 1; side += 2) {
        lv_obj_t *eye = lv_obj_create(btn);
        lv_obj_set_size(eye, EYE_PX, EYE_PX);
        lv_obj_set_style_radius(eye, LV_RADIUS_CIRCLE, 0);
        lv_obj_set_style_bg_color(eye, lv_color_black(), 0);
        lv_obj_set_style_border_width(eye, 0, 0);
        lv_obj_clear_flag(eye, LV_OBJ_FLAG_CLICKABLE | LV_OBJ_FLAG_SCROLLABLE);
        lv_obj_align(eye, LV_ALIGN_CENTER, side * 13, -10);
    }

    if (f.mouth == 0) {
        lv_obj_t *line = lv_obj_create(btn);
        lv_obj_set_size(line, MOUTH_PX - 6, 5);
        lv_obj_set_style_radius(line, 2, 0);
        lv_obj_set_style_bg_color(line, lv_color_black(), 0);
        lv_obj_set_style_border_width(line, 0, 0);
        lv_obj_clear_flag(line, LV_OBJ_FLAG_CLICKABLE | LV_OBJ_FLAG_SCROLLABLE);
        lv_obj_align(line, LV_ALIGN_CENTER, 0, 13);
        return;
    }
    // Part of a circle: the bottom of it is a smile, the top of it a frown.
    // LVGL angles: 0 = 3 o'clock, clockwise.
    lv_obj_t *arc = lv_arc_create(btn);
    lv_obj_set_size(arc, MOUTH_PX, MOUTH_PX);
    lv_arc_set_bg_angles(arc, 0, 0);
    lv_obj_set_style_arc_opa(arc, LV_OPA_TRANSP, LV_PART_MAIN);
    lv_obj_set_style_arc_color(arc, lv_color_black(), LV_PART_INDICATOR);
    lv_obj_set_style_arc_width(arc, 5, LV_PART_INDICATOR);
    lv_obj_set_style_arc_rounded(arc, true, LV_PART_INDICATOR);
    lv_obj_remove_style(arc, NULL, LV_PART_KNOB);
    lv_obj_clear_flag(arc, LV_OBJ_FLAG_CLICKABLE);
    if (f.mouth > 0) {
        lv_arc_set_angles(arc, 30, 150);
        lv_obj_align(arc, LV_ALIGN_CENTER, 0, -6);
    } else {
        lv_arc_set_angles(arc, 210, 330);
        lv_obj_align(arc, LV_ALIGN_CENTER, 0, 26);
    }
}

static void build()
{
    scr = lv_obj_create(NULL);
    lv_obj_set_style_bg_color(scr, lv_color_black(), 0);
    lv_obj_clear_flag(scr, LV_OBJ_FLAG_SCROLLABLE);

    lv_obj_t *title = lv_label_create(scr);
    lv_label_set_text(title, "How do you\nfeel now?");
    lv_obj_set_style_text_color(title, lv_color_white(), 0);
    lv_obj_set_style_text_font(title, &lv_font_montserrat_22, 0);
    lv_obj_set_style_text_align(title, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 8);

    for (int i = 0; i < 3; i++) {
        lv_coord_t x = (i - 1) * 78;
        make_face(scr, FACES[i], x);
        lv_obj_t *label = lv_label_create(scr);
        lv_label_set_text(label, FACES[i].label);
        lv_obj_set_style_text_color(label, lv_color_white(), 0);
        lv_obj_set_style_text_font(label, &lv_font_montserrat_18, 0);
        lv_obj_align(label, LV_ALIGN_CENTER, x, 48);
    }

    countdown = lv_bar_create(scr);
    lv_obj_set_size(countdown, 200, 6);
    lv_bar_set_range(countdown, 0, 1000);
    lv_obj_set_style_bg_color(countdown, lv_color_hex(0x333333), LV_PART_MAIN);
    lv_obj_set_style_bg_color(countdown, lv_color_hex(0x3FA7D6), LV_PART_INDICATOR);
    lv_obj_align(countdown, LV_ALIGN_BOTTOM_MID, 0, -12);
}

void checkin_show(lv_obj_t *return_to, checkin_done_cb on_done)
{
    if (active) finish(NULL);
    if (!scr) build();
    back_to = return_to;
    done_cb = on_done;
    active = true;

    lv_bar_set_value(countdown, 1000, LV_ANIM_OFF);
    lv_anim_t a;
    lv_anim_init(&a);
    lv_anim_set_var(&a, countdown);
    lv_anim_set_exec_cb(&a, bar_anim_cb);
    lv_anim_set_values(&a, 1000, 0);
    lv_anim_set_time(&a, CHECKIN_MS);
    lv_anim_start(&a);

    timeout = lv_timer_create(timeout_cb, CHECKIN_MS, NULL);
    lv_scr_load(scr);
}

bool checkin_active()
{
    return active;
}

void checkin_finish_now()
{
    finish(NULL);
}
