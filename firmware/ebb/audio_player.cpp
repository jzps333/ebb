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
static char         want_path[64] = "";
static float        want_gain = 0;
static bool         want_once = false;
static volatile bool request_pending = false;
static portMUX_TYPE req_mux = portMUX_INITIALIZER_UNLOCKED;

static char  playing_path[64] = "";
static bool  playing_once = false;
static char  loop_path[64] = "";   // the scene sound to come back to after a one-off clip
static float loop_gain = 0;

static void stop_now()
{
    if (mp3 && mp3->isRunning()) mp3->stop();
    if (file) {
        delete file;
        file = nullptr;
    }
    playing_path[0] = '\0';
}

static void start_now(const char *path, float gain, bool once = false)
{
    stop_now();
    playing_once = once;
    if (!path[0]) return;
    if (!FFat.exists(path)) {
        Serial.printf("[audio] missing %s\n", path);
        return;
    }
    file = new AudioFileSourceFS(FFat, path);
    out->SetGain(gain);
    bool ok = mp3->begin(file, out);
    if (ok) strlcpy(playing_path, path, sizeof(playing_path));
    if (once || !ok) Serial.printf("[audio] %s %s (%u bytes, gain %.2f)\n", ok ? "playing" : "cannot decode",
                                   path, (unsigned)file->getSize(), gain);
}

static void audio_task(void *)
{
    for (;;) {
        if (request_pending) {
            char path[64];
            float gain;
            bool once;
            taskENTER_CRITICAL(&req_mux);
            strlcpy(path, want_path, sizeof(path));
            gain = want_gain;
            once = want_once;
            request_pending = false;
            taskEXIT_CRITICAL(&req_mux);
            if (!once) {
                strlcpy(loop_path, path, sizeof(loop_path));  // "" = stop everything
                loop_gain = gain;
            }
            start_now(path, gain, once);
        }

        if (mp3->isRunning()) {
            if (!mp3->loop()) {
                // End of file. A one-off clip hands back to the scene sound;
                // the scene sound itself starts again (its seam is a cross-fade).
                char path[64];
                strlcpy(path, loop_path, sizeof(path));
                start_now(path, loop_gain);
            }
            vTaskDelay(1);
        } else {
            vTaskDelay(pdMS_TO_TICKS(20));
        }
    }
}

void audio_begin()
{
    // The speaker amp (MAX98357A) runs from the PMU's DLDO1 rail. LilyGoLib
    // switches it on but never sets its voltage, unlike every other rail, so
    // set 3.3 V (the amp is rated 2.5-5.5 V) and log what we found.
    uint16_t before = watch.getDLDO1Voltage();
    watch.setDLDO1Voltage(3300);
    watch.enableDLDO1();
    Serial.printf("[audio] speaker rail DLDO1 was %u mV, now %u mV (%s)\n",
                  before, watch.getDLDO1Voltage(), watch.isEnableDLDO1() ? "on" : "off");

    out = new AudioOutputI2S(1, AudioOutputI2S::EXTERNAL_I2S);
    out->SetPinout(BOARD_DAC_IIS_BCK, BOARD_DAC_IIS_WS, BOARD_DAC_IIS_DOUT);
    out->SetGain(0.1);
    mp3 = new AudioGeneratorMP3();
    // Core 0 with the network task, at a higher priority so HTTPS never starves it.
    xTaskCreatePinnedToCore(audio_task, "audio", 8192, nullptr, 3, nullptr, 0);
}

static void request(const char *path, float gain, bool once = false)
{
    taskENTER_CRITICAL(&req_mux);
    strlcpy(want_path, path, sizeof(want_path));
    want_gain = gain;
    want_once = once;
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

void audio_play_once(const char *path, float gain)
{
    request(path, gain, true);
}
