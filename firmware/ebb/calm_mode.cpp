#include <LilyGoLib.h>
#include "calm_mode.h"
#include "event_log.h"
#include "config.h"
#include "profile_store.h"
#include "media.h"
#include "audio_player.h"
#include "voice.h"

// Calm mode follows the approved calm profile (profile_store):
//   theme          -> looping scene video in the background (/video/<theme>.gif)
//   breath_pattern -> breathing circle + "Breathe in/Hold/Breathe out" on top,
//                     or no circle at all for "none" (the child dislikes it)
//   colors         -> circle colour
//   vibration      -> haptic on each breath in: off / gentle / medium
//   sound + volume -> looping sound (/audio/<sound>.mp3)
//   calm_message   -> text at the bottom

// ---- Tuning knobs ----------------------------------------------------------
static const int32_t CIRCLE_MIN_PX = 70;    // diameter at end of breath out
static const int32_t CIRCLE_MAX_PX = 200;   // diameter at end of breath in (screen is 240)
static const uint8_t HAPTIC_GENTLE = 7;     // DRV2605 library effect "Soft Bump - 100%"
static const uint8_t HAPTIC_MEDIUM = 47;    // "Buzz 1 - 100%"
static const int     VOICE_EVERY_BREATHS = 3;      // parent's voice on every 3rd breath in
static const uint32_t VOICE_EVERY_MS_NO_BREATH = 20000;  // ...or every 20 s with no breathing guide
static const float   VOICE_GAIN = 0.2f;

// One step of a breathing pattern. grow: +1 breathe in, -1 breathe out, 0 hold.
struct BreathStep {
    const char *label;
    uint32_t    ms;
    int8_t      grow;
};

static const BreathStep PATTERN_4_4[] = {{"Breathe in", 4000, 1}, {"Breathe out", 4000, -1}};
static const BreathStep PATTERN_4_6[] = {{"Breathe in", 4000, 1}, {"Breathe out", 6000, -1}};
static const BreathStep PATTERN_BOX[] = {{"Breathe in", 4000, 1}, {"Hold", 4000, 0},
                                         {"Breathe out", 4000, -1}, {"Hold", 4000, 0}};

// ---- State -----------------------------------------------------------------
static lv_obj_t *calm_scr      = NULL;  // our own screen, swapped in while calm runs
static lv_obj_t *backdrop      = NULL;  // the scene video (an lv_gif), made per session
static lv_obj_t *circle        = NULL;
static lv_obj_t *hint_label    = NULL;  // Breathe in / Hold / Breathe out
static lv_obj_t *message_label = NULL;  // the profile's calm_message
static lv_obj_t *prev_scr      = NULL;  // whatever was showing before start_calm()
static bool      running       = false;
static lv_timer_t *limit_timer = NULL;  // ends calm mode after CALM_MAX_MS
static lv_timer_t *step_timer  = NULL;  // advances to the next breathing step
static lv_timer_t *voice_timer = NULL;  // voice clips when there is no breathing guide
static int         breaths     = 0;

static CalmProfile        profile;
static const BreathStep  *steps = NULL;
static size_t             step_count = 0;
static size_t             step_index = 0;

// The parent's voice, quietly, between breaths. The scene sound pauses for
// the clip and comes back after it.
static void maybe_say_something()
{
    char path[64];  // "/voice/" + 36-char id + ".mp3"
    if (voice_next_clip(path, sizeof(path))) audio_play_once(path, VOICE_GAIN);
}

static void voice_timer_cb(lv_timer_t *t)
{
    maybe_say_something();
}

static void haptic_pulse()
{
    uint8_t effect = 0;
    if (!strcmp(profile.vibration, "gentle")) effect = HAPTIC_GENTLE;
    else if (!strcmp(profile.vibration, "medium")) effect = HAPTIC_MEDIUM;
    if (!effect) return;  // "off": the child finds vibration upsetting
    watch.setWaveform(0, effect);
    watch.setWaveform(1, 0);  // 0 = end of sequence, so only slot 0 plays
    watch.run();
}

static void size_cb(void *obj, int32_t size)
{
    lv_obj_set_size((lv_obj_t *)obj, size, size);
}

// Starts the current step: animates the circle (or holds it) and arms the
// timer for the next one.
static void run_step()
{
    const BreathStep &s = steps[step_index];
    lv_label_set_text(hint_label, s.label);

    if (s.grow != 0) {
        lv_anim_t a;
        lv_anim_init(&a);
        lv_anim_set_var(&a, circle);
        lv_anim_set_exec_cb(&a, size_cb);
        lv_anim_set_values(&a, lv_obj_get_width(circle), s.grow > 0 ? CIRCLE_MAX_PX : CIRCLE_MIN_PX);
        lv_anim_set_time(&a, s.ms);
        lv_anim_set_path_cb(&a, lv_anim_path_ease_in_out);
        lv_anim_start(&a);
    }
    if (s.grow > 0) {
        haptic_pulse();  // a pulse on each breath in
        // Start of every 3rd breath in after the first: the parent's voice.
        if (++breaths % VOICE_EVERY_BREATHS == 0) maybe_say_something();
    }

    lv_timer_set_period(step_timer, s.ms);
    lv_timer_reset(step_timer);
}

static void step_timer_cb(lv_timer_t *t)
{
    step_index = (step_index + 1) % step_count;
    run_step();
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

static void pick_pattern(const char *name)
{
    if (!strcmp(name, "slow_4_4"))         { steps = PATTERN_4_4; step_count = 2; }
    else if (!strcmp(name, "box_4_4_4_4")) { steps = PATTERN_BOX; step_count = 4; }
    else if (!strcmp(name, "none"))        { steps = NULL; step_count = 0; }
    else                                   { steps = PATTERN_4_6; step_count = 2; }
}

static float volume_gain(const char *volume)
{
    if (!strcmp(volume, "low")) return 0.06f;
    if (!strcmp(volume, "medium")) return 0.15f;
    return 0.0f;
}

void calm_mode_init()
{
    calm_scr = lv_obj_create(NULL);
    lv_obj_set_style_bg_color(calm_scr, lv_color_hex(0x0B1A2A), 0);
    lv_obj_clear_flag(calm_scr, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_event_cb(calm_scr, calm_scr_clicked_cb, LV_EVENT_CLICKED, NULL);

    // Translucent so the scene shows through; a soft ring makes it readable
    // on bright footage.
    circle = lv_obj_create(calm_scr);
    lv_obj_set_size(circle, CIRCLE_MIN_PX, CIRCLE_MIN_PX);
    lv_obj_set_style_radius(circle, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_opa(circle, LV_OPA_40, 0);
    lv_obj_set_style_border_color(circle, lv_color_white(), 0);
    lv_obj_set_style_border_opa(circle, LV_OPA_70, 0);
    lv_obj_set_style_border_width(circle, 3, 0);
    lv_obj_clear_flag(circle, LV_OBJ_FLAG_SCROLLABLE | LV_OBJ_FLAG_CLICKABLE);
    lv_obj_center(circle);

    hint_label = lv_label_create(calm_scr);
    lv_obj_set_style_text_color(hint_label, lv_color_white(), 0);
    lv_obj_set_style_text_font(hint_label, &lv_font_montserrat_20, 0);
    lv_obj_align(hint_label, LV_ALIGN_TOP_MID, 0, 8);

    // A dark band behind the message keeps it readable over any scene.
    message_label = lv_label_create(calm_scr);
    lv_obj_set_width(message_label, 240);
    lv_obj_set_style_text_align(message_label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_color(message_label, lv_color_white(), 0);
    lv_obj_set_style_text_font(message_label, &lv_font_montserrat_14, 0);
    lv_obj_set_style_bg_color(message_label, lv_color_black(), 0);
    lv_obj_set_style_bg_opa(message_label, LV_OPA_50, 0);
    lv_obj_set_style_pad_ver(message_label, 6, 0);
    lv_obj_align(message_label, LV_ALIGN_BOTTOM_MID, 0, 0);

    step_timer = lv_timer_create(step_timer_cb, 4000, NULL);
    lv_timer_pause(step_timer);
    voice_timer = lv_timer_create(voice_timer_cb, VOICE_EVERY_MS_NO_BREATH, NULL);
    lv_timer_pause(voice_timer);
}

void start_calm(const char *trigger, const char *command_id)
{
    if (running || !calm_scr) return;
    running = true;
    event_log_started(trigger, command_id);
    limit_timer = lv_timer_create(limit_timer_cb, CALM_MAX_MS, NULL);

    profile = profile_store_get();
    pick_pattern(profile.breath_pattern);

    // Scene video behind everything, if it has been downloaded yet.
    char path[40];
    snprintf(path, sizeof(path), "/video/%s.gif", profile.theme);
    if (media_has(path)) {
        char lv_path[44];
        snprintf(lv_path, sizeof(lv_path), "A:%s", path);
        backdrop = lv_gif_create(calm_scr);
        lv_gif_set_src(backdrop, lv_path);
        lv_obj_center(backdrop);
        lv_obj_clear_flag(backdrop, LV_OBJ_FLAG_CLICKABLE);
        lv_obj_move_background(backdrop);
    }

    lv_obj_set_style_bg_color(circle, lv_color_hex(profile_color_hex(profile.colors[0])), 0);
    lv_label_set_text(message_label, profile.calm_message);

    prev_scr = lv_scr_act();
    lv_scr_load(calm_scr);

    if (steps) {
        lv_obj_clear_flag(circle, LV_OBJ_FLAG_HIDDEN);
        lv_obj_clear_flag(hint_label, LV_OBJ_FLAG_HIDDEN);
        lv_obj_set_size(circle, CIRCLE_MIN_PX, CIRCLE_MIN_PX);
        step_index = 0;
        breaths = 0;
        lv_timer_resume(step_timer);
        run_step();  // the first breath in starts right now
    } else {
        // No breathing guide: just the scene, message and sound.
        lv_obj_add_flag(circle, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(hint_label, LV_OBJ_FLAG_HIDDEN);
        haptic_pulse();  // one gentle "I'm here" pulse, unless vibration is off
        lv_timer_reset(voice_timer);
        lv_timer_resume(voice_timer);
    }

    float gain = volume_gain(profile.volume);
    if (gain > 0 && strcmp(profile.sound, "none") != 0) {
        snprintf(path, sizeof(path), "/audio/%s.mp3", profile.sound);
        audio_play_loop(path, gain);
    }
}

void stop_calm()
{
    if (!running) return;
    running = false;

    if (limit_timer) {
        lv_timer_del(limit_timer);
        limit_timer = NULL;
    }
    lv_timer_pause(step_timer);
    lv_timer_pause(voice_timer);
    event_log_ended();

    lv_anim_del(circle, size_cb);
    audio_stop();
    watch.stop();  // cut any vibration still playing
    if (prev_scr) lv_scr_load(prev_scr);

    // The GIF decoder holds a full-screen buffer; free it between sessions.
    if (backdrop) {
        lv_obj_del(backdrop);
        backdrop = NULL;
    }
}

bool calm_is_running()
{
    return running;
}
