#pragma once
#include <stdint.h>

// Opt-in location (T-Watch S3 Plus GPS, TinyGPSPlus on GPSSerial). Does
// nothing unless settings.gps_enabled, and nothing at all on a watch without
// GPS. Keeps the latest fix, queues a trail point every 5 min, and the
// network task posts them to device-api/location.

struct GpsFix {
    double   lat;
    double   lng;
    float    accuracy_m;  // rough: HDOP x 5 m
    uint32_t at_ms;       // millis() of the fix
};

void gps_begin();               // main loop at boot, after watch.begin()
void gps_update();              // every loop(): reads NMEA without blocking
bool gps_latest(GpsFix &out);   // any task: fix no older than 10 min (and gps_enabled)
void gps_flush();               // network task: POST queued trail points
