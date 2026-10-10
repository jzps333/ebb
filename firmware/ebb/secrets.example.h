#pragma once

// Copy this file to secrets.h and fill in real values. secrets.h is never committed.

#define WIFI_SSID      "your-wifi-name"
#define WIFI_PASS      "your-wifi-password"

// No trailing slash. Real backend:  "https://<project-ref>.supabase.co/functions/v1"
// Local mock (tools/mock_device_api.py): "http://<your-computer-ip>:8787/functions/v1"
#define API_BASE_URL   "https://your-project-ref.supabase.co/functions/v1"

// The plain device token from the devices row you created by hand.
#define DEVICE_TOKEN   "paste-device-token-here"
