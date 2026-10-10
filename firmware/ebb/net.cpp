#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include "net.h"
#include "config.h"
#include "secrets.h"
#include "ca_certs.h"

// One client of each kind, reused between calls so HTTPS does not redo the
// slow TLS handshake every 3 seconds when the server keeps the connection open.
static WiFiClientSecure secure_client;
static WiFiClient       plain_client;
static HTTPClient       http;

static uint32_t last_wifi_attempt = 0;

// Set from the main loop and the network task, read by the network task.
static char         device_token[80] = "";
static portMUX_TYPE token_mux = portMUX_INITIALIZER_UNLOCKED;

void net_set_token(const char *token)
{
    taskENTER_CRITICAL(&token_mux);
    strlcpy(device_token, token, sizeof(device_token));
    taskEXIT_CRITICAL(&token_mux);
}

bool net_has_token()
{
    return device_token[0] != '\0';
}

void net_begin()
{
    WiFi.mode(WIFI_STA);
    WiFi.setAutoReconnect(true);
    WiFi.begin(WIFI_SSID, WIFI_PASS);
    last_wifi_attempt = millis();

    // Real clock for event timestamps, in UTC. Syncs on its own once WiFi is up.
    configTime(0, 0, "pool.ntp.org", "time.google.com");

    // Only trust servers whose certificate chains to one of these roots, so
    // nobody on the WiFi can pretend to be Supabase and steal the device token.
    secure_client.setCACert(ROOT_CA_BUNDLE);

    http.setReuse(true);
    http.setTimeout(HTTP_TIMEOUT_MS);
}

// Prints why WiFi isn't up: the status code and whether our network is
// visible at all. The ESP32 only sees 2.4 GHz networks.
static void log_wifi_problem()
{
    Serial.printf("[net] WiFi not connected, status=%d (1=SSID not found, 4=connect failed/wrong password, 6=disconnected)\n",
                  WiFi.status());
    int n = WiFi.scanNetworks();
    bool found = false;
    for (int i = 0; i < n; i++) {
        if (WiFi.SSID(i) == WIFI_SSID) {
            found = true;
            Serial.printf("[net] '%s' visible: channel %d, signal %d dBm\n",
                          WIFI_SSID, WiFi.channel(i), WiFi.RSSI(i));
        }
    }
    if (!found) {
        Serial.printf("[net] '%s' NOT visible on 2.4 GHz. Networks the watch can see (%d):\n", WIFI_SSID, n);
        for (int i = 0; i < n && i < 15; i++) {
            Serial.printf("[net]   %s (ch %d, %d dBm)\n", WiFi.SSID(i).c_str(), WiFi.channel(i), WiFi.RSSI(i));
        }
    }
    WiFi.scanDelete();
}

bool net_connected()
{
    static bool was_connected = false;
    if (WiFi.status() == WL_CONNECTED) {
        if (!was_connected) {
            Serial.printf("[net] WiFi connected, IP %s\n", WiFi.localIP().toString().c_str());
            was_connected = true;
        }
        return true;
    }
    was_connected = false;

    // Auto-reconnect usually handles drops; this is a backstop if it gives up.
    if (millis() - last_wifi_attempt > WIFI_RETRY_MS) {
        WiFi.disconnect();  // a scan fails while a connect attempt is running
        log_wifi_problem();
        last_wifi_attempt = millis();
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
    char token[sizeof(device_token)];
    taskENTER_CRITICAL(&token_mux);
    strlcpy(token, device_token, sizeof(token));
    taskEXIT_CRITICAL(&token_mux);
    if (token[0]) http.addHeader("Authorization", String("Bearer ") + token);
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
