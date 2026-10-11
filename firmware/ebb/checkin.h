#pragma once
#include <lvgl.h>

// After calm ends: a 10-second "How do you feel now?" screen with three big
// faces (better / same / worse). The answer, or NULL on timeout, goes to
// on_done, and the watch returns to return_to. Main loop / LVGL only.

typedef void (*checkin_done_cb)(const char *feeling);

void checkin_show(lv_obj_t *return_to, checkin_done_cb on_done);
bool checkin_active();
void checkin_finish_now();   // e.g. calm starting again: closes it with no answer
