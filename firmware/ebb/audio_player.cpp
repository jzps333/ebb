#include <Arduino.h>
#include <FFat.h>
#include <AudioOutputI2S.h>
#include <AudioFileSourceFS.h>
#include <AudioGeneratorMP3.h>
#include <LilyGoLib.h>
#include "audio_player.h"

// I2S port 1, as LilyGO recommends (port 0 is the PDM microphone's).
static AudioOutputI2S    *out  = nullptr;
static AudioFileSourceFS *file = nullptr;
static AudioGeneratorMP3 *mp3  = nullptr;

// What the main loop asked for; the audio task acts on it.
static char         want_path[40] = "";
static float        want_gain = 0;
static volatile bool request_pending = false;
static portMUX_TYPE req_mux = portMUX_INITIALIZER_UNLOCKED;

static char playing_path[40] = "";

static void stop_now()
{
    if (mp3 && mp3->isRunning()) mp3->stop();
    if (file) {
        delete file;
        file = nullptr;
    }
    playing_path[0] = '\0';
}

static void start_now(const char *path, float gain)
{
    stop_now();
    if (!path[0] || !FFat.exists(path)) return;
    file = new AudioFileSourceFS(FFat, path);
    out->SetGain(gain);
    if (mp3->begin(file, out)) strlcpy(playing_path, path, sizeof(playing_path));
}

static void audio_task(void *)
{
    for (;;) {
        if (request_pending) {
            char path[40];
            float gain;
            taskENTER_CRITICAL(&req_mux);
            strlcpy(path, want_path, sizeof(path));
            gain = want_gain;
            request_pending = false;
            taskEXIT_CRITICAL(&req_mux);
            start_now(path, gain);
        }

        if (mp3->isRunning()) {
            if (!mp3->loop()) {
                // End of file: play it again from the start (the clips are
                // made to loop, so the seam is a cross-fade, not a jump).
                char path[40];
                strlcpy(path, playing_path, sizeof(path));
                start_now(path, want_gain);
            }
            vTaskDelay(1);
        } else {
            vTaskDelay(pdMS_TO_TICKS(20));
        }
    }
}

void audio_begin()
{
    out = new AudioOutputI2S(1, AudioOutputI2S::EXTERNAL_I2S);
    out->SetPinout(BOARD_DAC_IIS_BCK, BOARD_DAC_IIS_WS, BOARD_DAC_IIS_DOUT);
    out->SetGain(0.1);
    mp3 = new AudioGeneratorMP3();
    // Core 0 with the network task, at a higher priority so HTTPS never starves it.
    xTaskCreatePinnedToCore(audio_task, "audio", 8192, nullptr, 3, nullptr, 0);
}

static void request(const char *path, float gain)
{
    taskENTER_CRITICAL(&req_mux);
    strlcpy(want_path, path, sizeof(want_path));
    want_gain = gain;
    request_pending = true;
    taskEXIT_CRITICAL(&req_mux);
}

void audio_play_loop(const char *path, float gain)
{
    request(path, gain);
}

void audio_stop()
{
    request("", 0);
}
