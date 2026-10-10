# Ebb watch firmware

Arduino sketch for the LilyGO T-Watch S3 Plus (no heart-rate sensor).

## Install (once)
1. Arduino IDE → Boards Manager → **esp32 by Espressif, version 2.0.9** (3.x breaks LilyGoLib).
2. Libraries in `~/Documents/Arduino/libraries`:
   - `TTGO_TWatch_Library` (t-watch-s3 branch), copied in whole
   - every folder from [T-Watch-Deps](https://github.com/Xinyuan-LilyGO/T-Watch-Deps): ESP8266Audio, IRremoteESP8266, RadioLib, SensorLib, TFT_eSPI, TinyGPSPlus, XPowersLib, arduinoFFT, lvgl
   - **ArduinoJson** 7.x (Library Manager)
3. `cp ebb/secrets.example.h ebb/secrets.h` and fill in WiFi (2.4 GHz), `API_BASE_URL`, `DEVICE_TOKEN`. `secrets.h` is gitignored.

## Board settings (Tools menu)
| Setting | Value |
|---|---|
| Board | ESP32S3 Dev Module |
| USB CDC On Boot | Enabled |
| PSRAM | OPI PSRAM |
| Flash Size | 16MB (128Mb) |
| Partition Scheme | 16M Flash (3MB APP/9.9MB FATFS) |

Open `ebb/ebb.ino`, pick the watch's port, Upload. Serial Monitor at 115200.

Screen upside down or sideways? Change `SCREEN_ROTATION` in `ebb/config.h` (0–3).

## Modules
| Module | Job | Status |
|---|---|---|
| `calm_mode` | Breathing circle, vibration on each breath in, ends after 3 min | built |
| `net` | WiFi + HTTP(S) to device-api | built |
| `commands` | Polls `device-api/poll` every 3 s, runs start/stop | built |
| `event_log` | Posts session start/end; queues offline | built |
| `profile_store` | Saves approved profile in flash | stub |
| `motion`, `noise`, `trigger_rules` | Automatic triggers | stub |
| `ui` | Themed home screen, "I need calm" / "I'm OK" | stub |
| `sounds.h` | Audio clips in program memory | stub |

## Testing without the backend
`tools/mock_device_api.py` pretends to be device-api over plain HTTP on your network, with the exact JSON from the plan:

```bash
python3 firmware/tools/mock_device_api.py dev-token
```

Set `API_BASE_URL` to `http://<your-computer-ip>:8787/functions/v1` and `DEVICE_TOKEN` to `dev-token`, then type `start` / `stop` in the terminal.

## Security note
`net.cpp` uses `setInsecure()` (encrypted, server not verified). Fine for the hackathon; pin the Supabase root CA with `setCACert()` before a real pilot.
