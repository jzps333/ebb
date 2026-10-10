#pragma once
#include <lvgl.h>

// QR pairing. A watch with no saved device token shows a pairing screen: a QR
// of a 6-digit code from device-api/pair/start. The parent scans it in the
// Ebb iPhone app and picks the child; the watch then receives its device
// token, saves it in flash, and keeps the QR up until the 15-minute code
// window ends (or Done is tapped) so the teacher can scan it too.

// Main loop. Loads the saved token (or DEVICE_TOKEN from secrets.h, if set).
// Shows the pairing screen when there is none; home_scr is shown afterwards.
void pairing_begin(lv_obj_t *home_scr);

// Network task, once per cycle. Gets a code, waits for the parent, saves the
// token, and tracks teachers joining while the window is open.
void pairing_network_tick();

// Main loop. Redraws the pairing screen when the network task changed it.
void pairing_ui_update();

// Main loop. Erases the saved token and starts pairing again (Serial 'u').
void pairing_forget();
