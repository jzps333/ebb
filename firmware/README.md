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
| `profile_store` | Saves approved profile in flash | built |
| `scenes` | Weekly scene set; prefers poll's `scene_pick` if it is in the set | built |
| `motion` | BMA423 at 25 Hz: energy x periodicity (0.5-3 Hz) score 0..1, main loop | built |
| `noise` | PDM mic RMS -> approx dB on its own task; audio never kept | built |
| `agitation` | Per-child baseline (NVS), z-scores, tiers 0-3, haptic cue, auto-start, cooldown | built |
| `settings` | Poll's `settings` (auto_motion/noise, k, gps) + `scene_pick`, saved in flash | built |
| `telemetry` | POST `/status` every ~5 s: agitation, tier, samples, battery | built |
| `checkin` | 10 s "How do you feel now?" faces after calm -> `child_feeling` | built |
| `gps` | Opt-in fix + 5-min trail -> POST `/location` (no-op without GPS) | built |
| `ui` | Themed home screen, "I need calm" / "I'm OK" | stub |
| `sounds.h` | Audio clips in program memory | stub |

Serial keys: `s` start calm, `x` stop, `v` voice test, `u` unpair, `a` print live
motion/noise/z/agitation/tier, `g` simulate high motion agitation for 20 s (auto-starts
calm after ~12 s even if auto_motion is off, unless in the 2-min cooldown).

## Testing without the backend
`tools/mock_device_api.py` pretends to be device-api over plain HTTP on your network, with the exact JSON from the plan:

```bash
python3 firmware/tools/mock_device_api.py dev-token
```

Set `API_BASE_URL` to `http://<your-computer-ip>:8787/functions/v1` and `DEVICE_TOKEN` to `dev-token`, then type `start` / `stop` in the terminal.

## Security note
`net.cpp` uses `setInsecure()` (encrypted, server not verified). Fine for the hackathon; pin the Supabase root CA with `setCACert()` before a real pilot.
