#include <LilyGoLib.h>
#include "calm_mode.h"
#include "event_log.h"
#include "config.h"

// ---- Tuning knobs ----------------------------------------------------------
static const uint32_t BREATH_IN_MS  = 4000;  // circle grows for this long
static const uint32_t BREATH_OUT_MS = 4000;  // circle shrinks for this long
static const int32_t  CIRCLE_MIN_PX = 60;    // diameter at end of breath out
static const int32_t  CIRCLE_MAX_PX = 210;   // diameter at end of breath in (screen is 240)
static const uint8_t  HAPTIC_EFFECT = 47;    // DRV2605 library effect: "Buzz 1 - 100%"

// ---- State -----------------------------------------------------------------
static lv_obj_t *calm_scr   = NULL;  // our own screen, swapped in while calm runs
static lv_obj_t *circle     = NULL;
static lv_obj_t *hint_label = NULL;
static lv_obj_t *prev_scr   = NULL;  // whatever was showing before start_calm()
static bool      running    = false;
static lv_timer_t *limit_timer = NULL;  // ends calm mode after CALM_MAX_MS

static int32_t last_size = 0;
static bool    growing   = true;

static void haptic_pulse()
{
    watch.setWaveform(0, HAPTIC_EFFECT);
    watch.setWaveform(1, 0);  // 0 = end of sequence, so only slot 0 plays
    watch.run();
}

// LVGL calls this every animation frame with the current diameter.
// Detects the turnaround points to update the label and fire the haptic.
static void breath_anim_cb(void *obj, int32_t size)
{
    lv_obj_set_size((lv_obj_t *)obj, size, size);

    if (size > last_size && !growing) {
        growing = true;
        lv_label_set_text(hint_label, "Breathe in");
        haptic_pulse();
    } else if (size < last_size && growing) {
        growing = false;
        lv_label_set_text(hint_label, "Breathe out");
    }
    last_size = size;
}

static void limit_timer_cb(lv_timer_t *t)
{
    Serial.println("[calm_mode] 3-minute limit reached");
    stop_calm();
}

// Tap anywhere on the calm screen to stop.
static void calm_scr_clicked_cb(lv_event_t *e)
{
    stop_calm();
}

void calm_mode_init()
{
    calm_scr = lv_obj_create(NULL);
    lv_obj_set_style_bg_color(calm_scr, lv_color_black(), 0);
    lv_obj_clear_flag(calm_scr, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_event_cb(calm_scr, calm_scr_clicked_cb, LV_EVENT_CLICKED, NULL);

    circle = lv_obj_create(calm_scr);
    lv_obj_set_size(circle, CIRCLE_MIN_PX, CIRCLE_MIN_PX);
    lv_obj_set_style_radius(circle, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(circle, lv_color_hex(0x3FA7D6), 0);
    lv_obj_set_style_border_width(circle, 0, 0);
    lv_obj_clear_flag(circle, LV_OBJ_FLAG_SCROLLABLE | LV_OBJ_FLAG_CLICKABLE);
    lv_obj_center(circle);

    hint_label = lv_label_create(calm_scr);
    lv_obj_set_style_text_color(hint_label, lv_color_white(), 0);
    lv_obj_set_style_text_font(hint_label, &lv_font_montserrat_20, 0);
    lv_label_set_text(hint_label, "Breathe in");
    lv_obj_align(hint_label, LV_ALIGN_BOTTOM_MID, 0, -6);
}

void start_calm(const char *trigger, const char *command_id)
{
    if (running || !calm_scr) return;
    running = true;
    event_log_started(trigger, command_id);
    limit_timer = lv_timer_create(limit_timer_cb, CALM_MAX_MS, NULL);

    prev_scr = lv_scr_act();
    lv_scr_load(calm_scr);

    lv_obj_set_size(circle, CIRCLE_MIN_PX, CIRCLE_MIN_PX);
    last_size = CIRCLE_MIN_PX;
    growing   = true;
    lv_label_set_text(hint_label, "Breathe in");
    haptic_pulse();  // the first breath in starts right now

    lv_anim_t a;
    lv_anim_init(&a);
    lv_anim_set_var(&a, circle);
    lv_anim_set_exec_cb(&a, breath_anim_cb);
    lv_anim_set_values(&a, CIRCLE_MIN_PX, CIRCLE_MAX_PX);
    lv_anim_set_time(&a, BREATH_IN_MS);
    lv_anim_set_playback_time(&a, BREATH_OUT_MS);
    lv_anim_set_repeat_count(&a, LV_ANIM_REPEAT_INFINITE);
    lv_anim_set_path_cb(&a, lv_anim_path_ease_in_out);
    lv_anim_start(&a);
}

void stop_calm()
{
    if (!running) return;
    running = false;

    if (limit_timer) {
        lv_timer_del(limit_timer);
        limit_timer = NULL;
    }
    event_log_ended();

    lv_anim_del(circle, breath_anim_cb);
    watch.stop();  // cut any vibration still playing
    if (prev_scr) lv_scr_load(prev_scr);
}

bool calm_is_running()
{
    return running;
}
