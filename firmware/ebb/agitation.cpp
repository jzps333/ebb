#include <LilyGoLib.h>
#include <Preferences.h>
#include <math.h>
#include "agitation.h"
#include "motion.h"
#include "noise.h"
#include "settings.h"
#include "telemetry.h"
#include "calm_mode.h"
#include "checkin.h"
#include "profile_store.h"
#include "config.h"

// ---- Tuning knobs ----------------------------------------------------------
static const uint32_t TICK_MS        = 200;     // 5 Hz
static const float    SMOOTH_ALPHA   = 0.065f;  // EWMA over ~3 s at 5 Hz
static const float    BASE_ALPHA     = 1.0f / (20 * 60 * 5);  // baseline drifts over ~20 min
static const uint32_t PRIOR_N        = 150;     // a fresh baseline trusts its prior for ~30 s
static const float    RISE_LEVEL     = 0.6f;
static const float    CALM_LEVEL     = 1.0f;
static const float    SETTLE_LEVEL   = 0.4f;
static const uint32_t RISE_DWELL_MS  = 5000;
static const uint32_t MOTION_DWELL_MS = 6000;
static const uint32_t NOISE_DWELL_MS = 5000;
static const uint32_t ADULT_AFTER_MS = 60000;
static const uint32_t SETTLE_DWELL_MS = 10000;
static const uint32_t CUE_REPEAT_MS  = 60000;   // breathing cue again if still rising
static const int      CUE_BREATHS    = 3;
static const uint32_t CUE_BREATH_MS  = 6000;
static const float    SIM_TERM       = 2.0f;    // 'g': agitation target while simulating

// Per signal: [0] motion score, [1] noise dB.
enum { MOTION = 0, NOISE = 1 };
struct Baseline {
    float    mean;
    float    var;
    uint32_t n;
};
// The child's normal starts from these until it has learned its own.
static const Baseline PRIOR[2] = { {0.10f, 0.12f * 0.12f, PRIOR_N}, {55.0f, 6.0f * 6.0f, PRIOR_N} };
static const float    STD_FLOOR[2] = { 0.18f, 4.0f };  // never trust a tiny variance
// Below this repetitive-motion score, movement never counts as agitation, so a
// baseline learned on a still table can't turn everyday arm movement into an alarm.
static const float    MOTION_MIN_SCORE = 0.35f;
static const uint32_t BASELINE_MAGIC = 0xEBBBA5E1;

struct SavedBaseline {
    uint32_t magic;
    Baseline b[2];
};

// ---- State (main loop only) -------------------------------------------------
static Baseline base[2];
static float    z[2] = {0, NAN};
static float    term[2] = {0, 0};       // smoothed z / k
static float    level = 0;              // agitation
static int      dominant = MOTION;
static int      tier = 0;

static uint32_t next_tick = 0;
static uint32_t rise_since = 0, calm_since = 0, settle_since = 0;  // 0 = not above/below
static uint32_t calm_started_ms = 0;
static uint32_t cooldown_until = 0;
static bool     in_session = false;
static float    session_peak = 0;
static int      session_tier = 0;
static uint32_t sim_until = 0;
static uint32_t last_sample = 0, last_save = 0;
static int      battery_pct = -1;

// Agitation peak of the minute before calm: max per second, last 60 s.
static float    recent_max[60];
static uint32_t recent_sec = 0;

// Breathing cue on the wrist (tier 1).
static lv_timer_t *cue_timer = NULL;
static int         cue_left = 0;
static uint32_t    last_cue = 0;

static bool simulating()
{
    return sim_until && (int32_t)(sim_until - millis()) > 0;
}

// ---- Baseline -------------------------------------------------------------

static void save_baseline()
{
    SavedBaseline s = { BASELINE_MAGIC, { base[0], base[1] } };
    Preferences prefs;
    prefs.begin("ebb", false);
    prefs.putBytes("baseline", &s, sizeof(s));
    prefs.end();
}

// Exponentially weighted mean and variance (Welford-style). Early on the
// weight is 1/n so a new watch learns quickly, then it settles to BASE_ALPHA.
static void learn(Baseline &b, float x)
{
    float a = 1.0f / (float)(b.n + 1);
    if (a < BASE_ALPHA) a = BASE_ALPHA;
    float d = x - b.mean;
    b.mean += a * d;
    b.var = (1.0f - a) * (b.var + a * d * d);
    if (b.n < 0xFFFFFF) b.n++;
}

static float zscore(const Baseline &b, float x, float floor)
{
    float sd = sqrtf(b.var);
    return (x - b.mean) / (sd > floor ? sd : floor);
}

void agitation_reset_baseline()
{
    base[0] = PRIOR[0];
    base[1] = PRIOR[1];
    save_baseline();
    Serial.println("[agitation] baseline reset");
}

// ---- Haptic breathing cue ------------------------------------------------------

// One slow breath: ramp up (in), 1 s pause, ramp down (out).
static void cue_breath()
{
    watch.setWaveform(0, 82);          // Transition Ramp Up Long Smooth 1
    watch.setWaveform(1, 0x80 | 100);  // wait 100 x 10 ms
    watch.setWaveform(2, 70);          // Transition Ramp Down Long Smooth 1
    watch.setWaveform(3, 0);           // end of sequence
    watch.run();
}

static void cue_timer_cb(lv_timer_t *t)
{
    if (calm_is_running() || --cue_left <= 0) {
        lv_timer_pause(cue_timer);
        return;
    }
    cue_breath();
}

static void start_cue()
{
    last_cue = millis();
    if (!strcmp(profile_store_get().vibration, "off")) return;  // the child finds vibration upsetting
    if (!(watch.getDeviceProbe() & WATCH_DRV_ONLINE)) return;
    Serial.println("[agitation] tier 1: breathing cue");
    cue_left = CUE_BREATHS;
    cue_breath();
    lv_timer_reset(cue_timer);
    lv_timer_resume(cue_timer);
}

// ---- Tiers -----------------------------------------------------------------

static bool signal_enabled(int sig, const AdaptiveSettings &s)
{
    if (sig == MOTION) return s.auto_motion || simulating();
    return s.auto_noise && !isnan(z[NOISE]);
}

static void set_tier(int t)
{
    if (t == tier) return;
    Serial.printf("[agitation] tier %d -> %d (agitation %.2f)\n", tier, t, level);
    tier = t;
    if (in_session && t > session_tier) session_tier = t;
}

static uint32_t held(uint32_t since, uint32_t now)
{
    return (since && (int32_t)(now - since) > 0) ? now - since : 0;
}

static void run_tiers(const AdaptiveSettings &s, uint32_t now)
{
    // Timers for "above X since" / "below 0.4 since"; 0 = not. A millis()
    // of exactly 0 is stored as 1 so it still counts as set.
    uint32_t stamp = now ? now : 1;
    // Hysteresis: real rocking and flapping come in bursts, so a timer starts
    // when the level crosses its line and only resets once the level has
    // clearly dropped (to 70% of the line), not on every brief dip.
    if (level >= RISE_LEVEL) { if (!rise_since) rise_since = stamp; }
    else if (level < RISE_LEVEL * 0.7f) rise_since = 0;
    if (level >= CALM_LEVEL) { if (!calm_since) calm_since = stamp; }
    else if (level < CALM_LEVEL * 0.7f) calm_since = 0;
    settle_since = level < SETTLE_LEVEL ? (settle_since ? settle_since : stamp) : 0;

    bool calm = calm_is_running();
    bool dom_enabled = signal_enabled(dominant, s);
    uint32_t calm_dwell = dominant == NOISE ? NOISE_DWELL_MS : MOTION_DWELL_MS;

    if (held(settle_since, now) >= SETTLE_DWELL_MS) {
        set_tier(0);
    } else if (calm) {
        if (tier < 2 && held(calm_since, now) >= calm_dwell) set_tier(2);
        if (tier < 3 && now - calm_started_ms >= ADULT_AFTER_MS && level >= CALM_LEVEL) set_tier(3);
    } else {
        if (tier == 0 && held(rise_since, now) >= RISE_DWELL_MS) {
            set_tier(1);
            if (dom_enabled) start_cue();
        } else if (tier == 1 && dom_enabled && now - last_cue >= CUE_REPEAT_MS) {
            start_cue();
        }
        bool cooling = (int32_t)(cooldown_until - now) > 0 || checkin_active();
        if (tier <= 1 && held(calm_since, now) >= calm_dwell && dom_enabled && !cooling) {
            const char *trigger = dominant == NOISE ? "noise" : "motion";
            Serial.printf("[agitation] tier 2: start_calm(\"%s\")\n", trigger);
            start_calm(trigger);  // calls agitation_session_started(), which sets tier 2
        }
    }

    if (in_session && level > session_peak) session_peak = level;
}

// ---- Public -----------------------------------------------------------------

void agitation_begin()
{
    base[0] = PRIOR[0];
    base[1] = PRIOR[1];
    Preferences prefs;
    prefs.begin("ebb", true);
    SavedBaseline saved = {};
    size_t n = prefs.getBytes("baseline", &saved, sizeof(saved));
    prefs.end();
    if (n == sizeof(saved) && saved.magic == BASELINE_MAGIC) {
        base[0] = saved.b[0];
        base[1] = saved.b[1];
    }
    Serial.printf("[agitation] baseline motion %.3f+-%.3f, noise %.1f+-%.1f dB\n",
                  base[0].mean, sqrtf(base[0].var), base[1].mean, sqrtf(base[1].var));

    cue_timer = lv_timer_create(cue_timer_cb, CUE_BREATH_MS, NULL);
    lv_timer_pause(cue_timer);
    last_save = last_sample = next_tick = millis();
}

void agitation_update()
{
    uint32_t now = millis();
    if ((int32_t)(now - next_tick) < 0) return;
    next_tick = now + TICK_MS;

    AdaptiveSettings s = settings_get();
    float x[2] = { motion_score(), noise_db() };
    bool calm = calm_is_running();

    z[MOTION] = zscore(base[MOTION], x[MOTION], STD_FLOOR[MOTION]);
    z[NOISE]  = isnan(x[NOISE]) ? NAN : zscore(base[NOISE], x[NOISE], STD_FLOOR[NOISE]);
    bool sim = simulating();
    if (sim && z[MOTION] < SIM_TERM * s.motion_k) z[MOTION] = SIM_TERM * s.motion_k;

    float raw[2];
    raw[MOTION] = (z[MOTION] > 0 && (x[MOTION] >= MOTION_MIN_SCORE || sim)) ? z[MOTION] / s.motion_k : 0;
    // During calm the mic mostly hears the watch's own scene sound and voice,
    // so noise does not count until calm is over.
    raw[NOISE] = (isnan(z[NOISE]) || calm || z[NOISE] < 0) ? 0 : z[NOISE] / s.noise_k;
    for (int i = 0; i < 2; i++) term[i] += SMOOTH_ALPHA * (raw[i] - term[i]);

    // Agitation counts the signals the parent turned on. With neither on, the
    // watch still reports both (the app's live graph), it just never acts.
    bool en_m = signal_enabled(MOTION, s), en_n = signal_enabled(NOISE, s);
    bool any = en_m || en_n;
    float a_m = (!any || en_m) ? term[MOTION] : 0;
    float a_n = (!any || en_n) ? term[NOISE] : 0;
    dominant = a_n > a_m ? NOISE : MOTION;
    level = a_m > a_n ? a_m : a_n;

    run_tiers(s, now);

    // Learn the child's normal only while they are settled: never during calm,
    // the check-in, a simulation, or while that signal is itself raised.
    bool settled = tier == 0 && !calm && !checkin_active() && !sim;
    if (settled && term[MOTION] < RISE_LEVEL) learn(base[MOTION], x[MOTION]);
    if (settled && !isnan(x[NOISE]) && term[NOISE] < RISE_LEVEL) learn(base[NOISE], x[NOISE]);
    if (now - last_save >= BASELINE_SAVE_MS) {
        last_save = now;
        save_baseline();
    }

    // Per-second maxima for the peak of the minute before a session.
    uint32_t sec = now / 1000;
    if (sec != recent_sec) {
        recent_sec = sec;
        recent_max[sec % 60] = level;
    } else if (level > recent_max[sec % 60]) {
        recent_max[sec % 60] = level;
    }

    if (now - last_sample >= SAMPLE_EVERY_MS) {
        last_sample = now;
        battery_pct = watch.isBatteryConnect() ? watch.getBatteryPercent() : -1;
        SensorSample smp = { now, x[MOTION], x[NOISE], z[MOTION], z[NOISE], level };
        telemetry_add_sample(smp);
    }
    telemetry_set_state(level, tier, calm, battery_pct);
}

float agitation_level()
{
    return level;
}

int agitation_tier()
{
    return tier;
}

void agitation_session_started()
{
    uint32_t now = millis();
    in_session = true;
    calm_started_ms = now;
    session_peak = level;
    for (int i = 0; i < 60; i++) if (recent_max[i] > session_peak) session_peak = recent_max[i];
    session_tier = 0;
    if (cue_timer) lv_timer_pause(cue_timer);
    // An automatic start is the tier-2 response; a teacher or child start
    // only reaches tier 2 if agitation itself gets there.
    if (level >= CALM_LEVEL && held(calm_since, now) > 0) set_tier(2);
    session_tier = tier;
}

void agitation_session_ended(float &peak, int &out_tier)
{
    peak = session_peak;
    out_tier = session_tier;
    in_session = false;
    cooldown_until = millis() + AUTO_COOLDOWN_MS;
    if (tier >= 2) set_tier(level >= SETTLE_LEVEL ? 1 : 0);
    last_cue = millis();  // no cue straight after calm; it comes back if still rising in a minute
}

void agitation_simulate(uint32_t ms)
{
    sim_until = millis() + ms;
    if (!sim_until) sim_until = 1;
    Serial.printf("[agitation] simulating high motion agitation for %lu s\n", (unsigned long)(ms / 1000));
}

void agitation_print()
{
    AdaptiveSettings s = settings_get();
    Serial.printf("[agitation] motion %.3f (z %.2f, base %.3f+-%.3f) | noise %.1f dB (z %.2f, base %.1f+-%.1f)\n",
                  motion_score(), z[MOTION], base[MOTION].mean, sqrtf(base[MOTION].var),
                  noise_db(), z[NOISE], base[NOISE].mean, sqrtf(base[NOISE].var));
    Serial.printf("[agitation] terms m=%.2f n=%.2f -> agitation %.2f, tier %d, dominant %s%s%s\n",
                  term[MOTION], term[NOISE], level, tier, dominant == NOISE ? "noise" : "motion",
                  simulating() ? ", SIMULATING" : "",
                  (int32_t)(cooldown_until - millis()) > 0 ? ", cooldown" : "");
    Serial.printf("[agitation] auto_motion=%d auto_noise=%d motion_k=%.2f noise_k=%.2f\n",
                  s.auto_motion, s.auto_noise, s.motion_k, s.noise_k);
}
