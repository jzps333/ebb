#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include "net.h"
#include "config.h"
#include "secrets.h"

// One client of each kind, reused between calls so HTTPS does not redo the
// slow TLS handshake every 3 seconds when the server keeps the connection open.
static WiFiClientSecure secure_client;
static WiFiClient       plain_client;
static HTTPClient       http;

static uint32_t last_wifi_attempt = 0;

void net_begin()
{
    WiFi.mode(WIFI_STA);
    WiFi.setAutoReconnect(true);
    WiFi.begin(WIFI_SSID, WIFI_PASS);
    last_wifi_attempt = millis();

    // HACKATHON SHORTCUT: skips checking the server's certificate, so the
    // connection is encrypted but not verified. Before a real pilot, replace
    // with secure_client.setCACert(<root CA of your Supabase host>).
    secure_client.setInsecure();

    http.setReuse(true);
    http.setTimeout(HTTP_TIMEOUT_MS);
}

bool net_connected()
{
    if (WiFi.status() == WL_CONNECTED) return true;

    // Auto-reconnect usually handles drops; this is a backstop if it gives up.
    if (millis() - last_wifi_attempt > WIFI_RETRY_MS) {
        last_wifi_attempt = millis();
        WiFi.disconnect();
        WiFi.begin(WIFI_SSID, WIFI_PASS);
    }
    return false;
}

static bool open_request(const String &path)
{
    String url = String(API_BASE_URL) + path;
    bool ok = url.startsWith("https://")
                  ? http.begin(secure_client, url)
                  : http.begin(plain_client, url);
    if (!ok) return false;
    http.addHeader("Authorization", String("Bearer ") + DEVICE_TOKEN);
    return true;
}

static int finish_request(int code, String &body_out)
{
    body_out = code > 0 ? http.getString() : String();
    http.end();  // with setReuse(true) this keeps the socket open for next time
    return code;
}

int net_get(const String &path, String &body_out)
{
    if (!net_connected()) return -100;
    if (!open_request(path)) return -101;
    return finish_request(http.GET(), body_out);
}

int net_post(const String &path, const String &json_body, String &body_out)
{
    if (!net_connected()) return -100;
    if (!open_request(path)) return -101;
    http.addHeader("Content-Type", "application/json");
    return finish_request(http.POST(json_body), body_out);
}
