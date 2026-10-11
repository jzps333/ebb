#include <LilyGoLib.h>
#include <math.h>
#include "motion.h"

// ---- Tuning knobs ----------------------------------------------------------
static const uint32_t SAMPLE_MS    = 40;     // 25 Hz
static const int      WINDOW       = 128;    // ~5 s of samples
static const int      SCORE_EVERY  = 8;      // rescore every 8 samples (~3 Hz)
static const float    LSB_PER_G    = 512.0f; // +-4 g range, 12-bit (getAccelerometer divides by 16)
static const float    GRAVITY_ALPHA = 0.02f; // slow EWMA = gravity + posture (~2 s)
static const float    ENERGY_SCALE = 0.2f;   // g RMS where the energy term reaches ~63%
static const int      LAG_MIN = 8;           // 25 Hz / 3 Hz
static const int      LAG_MAX = 50;          // 25 Hz / 0.5 Hz

// ---- State (main loop only) --------------------------------------------------
static bool     online = false;
static uint32_t next_sample_ms = 0;
static float    gravity = 1.0f;
static float    window[WINDOW];   // high-passed magnitude, ring buffer
static int      head = 0;         // next slot to write
static int      filled = 0;
static int      since_score = 0;
static float    score = 0;

// Energy x periodicity over the window, oldest sample first.
static float compute_score()
{
    static float x[WINDOW];
    for (int i = 0; i < WINDOW; i++) x[i] = window[(head + i) % WINDOW];

    float energy = 0;
    for (int i = 0; i < WINDOW; i++) energy += x[i] * x[i];
    if (energy <= 0) return 0;
    float rms = sqrtf(energy / WINDOW);
    float energy_term = 1.0f - expf(-rms / ENERGY_SCALE);

    // Normalised autocorrelation, bias-corrected for the shorter overlap at
    // long lags. A steady rhythm in 0.5-3 Hz gives a peak near 1.
    float best = 0;
    for (int lag = LAG_MIN; lag <= LAG_MAX; lag++) {
        float sum = 0;
        for (int i = 0; i + lag < WINDOW; i++) sum += x[i] * x[i + lag];
        float r = (sum / energy) * (float)WINDOW / (float)(WINDOW - lag);
        if (r > best) best = r;
    }
    float periodicity = best > 1.0f ? 1.0f : best;
    return energy_term * periodicity;
}

void motion_begin()
{
    online = watch.getDeviceProbe() & WATCH_BMA_ONLINE;
    if (!online) {
        Serial.println("[motion] BMA423 not found: motion score stays 0");
        return;
    }
    watch.configAccelerometer();  // 4 G, 200 Hz, averaging 4, continuous
    watch.enableAccelerometer();
    next_sample_ms = millis();
}

void motion_update()
{
    if (!online) return;
    uint32_t now = millis();
    if ((int32_t)(now - next_sample_ms) < 0) return;
    // One sample per call; after a long stall (GIF decode, flash write) skip
    // ahead instead of reading a burst of samples at the same moment.
    next_sample_ms = (now - next_sample_ms > 4 * SAMPLE_MS) ? now + SAMPLE_MS : next_sample_ms + SAMPLE_MS;

    int16_t x, y, z;
    if (!watch.getAccelerometer(x, y, z)) return;
    float mag = sqrtf((float)x * x + (float)y * y + (float)z * z) / LSB_PER_G;
    gravity += GRAVITY_ALPHA * (mag - gravity);

    window[head] = mag - gravity;
    head = (head + 1) % WINDOW;
    if (filled < WINDOW) filled++;
    if (filled == WINDOW && ++since_score >= SCORE_EVERY) {
        since_score = 0;
        score = compute_score();
    }
}

float motion_score()
{
    return score;
}

bool motion_available()
{
    return online;
}
