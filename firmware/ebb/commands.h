#pragma once
#include <Arduino.h>

// Polls device-api/poll every POLL_INTERVAL_MS on a background task and
// runs start_calm / stop_calm. Network work happens on core 0; the actual
// start/stop calls happen in commands_handle() on the main loop, because
// LVGL must only be touched from one task.

void commands_begin();
void commands_handle();          // call every loop()

// For a status line on screen / Serial.
int      commands_last_http_code();  // 0 = no poll yet, <0 = network error
uint32_t commands_last_poll_ms();    // millis() of the last completed poll
