#include <ArduinoJson.h>
#include "commands.h"
#include "net.h"
#include "config.h"
#include "calm_mode.h"

enum CommandType : uint8_t { CMD_START_CALM, CMD_STOP_CALM };

struct Command {
    CommandType type;
    char id[40];  // UUIDs are 36 chars
};

static QueueHandle_t cmd_queue = NULL;

static volatile int      last_http_code = 0;
static volatile uint32_t last_poll_ms   = 0;

// Until profile_store exists we have no saved profile, so report version 0.
static int current_profile_version = 0;

// Parses: { "commands": [ { "id": "…", "type": "start_calm" } ], "profile": null }
static void parse_poll_response(const String &body)
{
    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, body);
    if (err) {
        Serial.printf("[commands] bad JSON: %s\n", err.c_str());
        return;
    }

    for (JsonObject c : doc["commands"].as<JsonArray>()) {
        const char *type = c["type"] | "";
        const char *id   = c["id"] | "";

        Command cmd;
        if (strcmp(type, "start_calm") == 0) {
            cmd.type = CMD_START_CALM;
        } else if (strcmp(type, "stop_calm") == 0) {
            cmd.type = CMD_STOP_CALM;
        } else {
            Serial.printf("[commands] unknown type '%s', ignored\n", type);
            continue;
        }
        strlcpy(cmd.id, id, sizeof(cmd.id));
        xQueueSend(cmd_queue, &cmd, 0);
    }
    // doc["profile"] is handled later by profile_store.
}

static void poll_task(void *arg)
{
    String body;
    for (;;) {
        uint32_t started = millis();

        String path = String("/device-api/poll?profile_version=") + current_profile_version;
        int code = net_get(path, body);
        last_http_code = code;
        last_poll_ms   = millis();

        if (code == 200) {
            parse_poll_response(body);
        } else if (code != -100) {  // -100 = WiFi not up yet, not worth logging every time
            Serial.printf("[commands] poll failed: %d %s\n", code, body.c_str());
        }

        // Keep a steady 3 s rhythm even if the request itself took a while.
        uint32_t spent = millis() - started;
        vTaskDelay(pdMS_TO_TICKS(spent < POLL_INTERVAL_MS ? POLL_INTERVAL_MS - spent : 0));
    }
}

void commands_begin()
{
    net_begin();
    cmd_queue = xQueueCreate(8, sizeof(Command));
    // 16 KB stack: TLS needs a lot. Core 0, so the UI on core 1 never waits on the network.
    xTaskCreatePinnedToCore(poll_task, "cmd_poll", 16384, NULL, 1, NULL, 0);
}

void commands_handle()
{
    Command cmd;
    while (xQueueReceive(cmd_queue, &cmd, 0) == pdTRUE) {
        if (cmd.type == CMD_START_CALM) {
            Serial.printf("[commands] start_calm (%s)\n", cmd.id);
            start_calm();
        } else {
            Serial.printf("[commands] stop_calm (%s)\n", cmd.id);
            stop_calm();
        }
    }
}

int commands_last_http_code()
{
    return last_http_code;
}

uint32_t commands_last_poll_ms()
{
    return last_poll_ms;
}
