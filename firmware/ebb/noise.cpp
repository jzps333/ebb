#include <LilyGoLib.h>
#include <math.h>
#include "noise.h"
#include "config.h"

static const size_t FRAME_SAMPLES = MIC_I2S_SAMPLE_RATE / 10;  // 100 ms
static const float  POWER_ALPHA   = 0.2f;   // EWMA of frame power: ~1 s
static const float  FLOOR_DBFS    = -100.0f;

// Written by the noise task, read by any task.
static float        latest_db = NAN;
static portMUX_TYPE db_mux = portMUX_INITIALIZER_UNLOCKED;

static void noise_task(void *)
{
    // Overwritten every frame; only its RMS ever leaves this function.
    static int16_t frame[FRAME_SAMPLES];
    float power = 0;   // smoothed mean square, full scale = 1.0
    bool  primed = false;

    for (;;) {
        size_t got = 0;
        if (!watch.readMicrophone(frame, sizeof(frame), &got, pdMS_TO_TICKS(500)) || got == 0) {
            vTaskDelay(pdMS_TO_TICKS(100));
            continue;
        }
        size_t n = got / sizeof(int16_t);

        // Remove the DC offset, then mean square of the frame.
        float mean = 0;
        for (size_t i = 0; i < n; i++) mean += frame[i];
        mean /= n;
        float ms = 0;
        for (size_t i = 0; i < n; i++) {
            float v = (frame[i] - mean) / 32768.0f;
            ms += v * v;
        }
        ms /= n;

        power = primed ? power + POWER_ALPHA * (ms - power) : ms;
        primed = true;
        float dbfs = power > 0 ? 10.0f * log10f(power) : FLOOR_DBFS;
        if (dbfs < FLOOR_DBFS) dbfs = FLOOR_DBFS;

        taskENTER_CRITICAL(&db_mux);
        latest_db = dbfs + NOISE_DB_OFFSET;
        taskEXIT_CRITICAL(&db_mux);
    }
}

void noise_begin()
{
    if (!watch.initMicrophone()) {
        Serial.println("[noise] microphone init failed: noise stays unknown");
        return;
    }
    // Priority 1 on core 0: mostly asleep in i2s_read, never in the UI's way.
    xTaskCreatePinnedToCore(noise_task, "noise", 4096, nullptr, 1, nullptr, 0);
}

float noise_db()
{
    taskENTER_CRITICAL(&db_mux);
    float v = latest_db;
    taskEXIT_CRITICAL(&db_mux);
    return v;
}
