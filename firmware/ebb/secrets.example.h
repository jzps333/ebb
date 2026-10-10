#pragma once

// Copy this file to secrets.h and fill in real values. secrets.h is never committed.

#define WIFI_SSID      "your-wifi-name"
#define WIFI_PASS      "your-wifi-password"

// No trailing slash. Real backend:  "https://<project-ref>.supabase.co/functions/v1"
// Local mock (tools/mock_device_api.py): "http://<your-computer-ip>:8787/functions/v1"
#define API_BASE_URL   "https://your-project-ref.supabase.co/functions/v1"

// Leave empty: the watch pairs by QR with the Ebb iPhone app and keeps its
// token in flash. Only paste a token here to skip pairing while developing.
#define DEVICE_TOKEN   ""
