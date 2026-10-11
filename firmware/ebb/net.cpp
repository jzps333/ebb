#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <time.h>
#include <sys/time.h>
#include "net.h"
#include "config.h"
#include "secrets.h"
#include "ca_certs.h"
#include <FFat.h>

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

bool net_clock_ready()
{
    return time(nullptr) > 1700000000;  // after Nov 2023, so not the 1970 boot clock
}

// The boot time (real clock minus millis) is worked out once and reused, so
// the same millis() always gives the same string. Recomputing it each call
// could round to a different second, and the server matches a session's start
// and end reports by started_at.
bool net_iso_time(uint32_t ms, char *out, size_t len)
{
    static int64_t boot_epoch_ms = 0;
    if (boot_epoch_ms == 0) {
        struct timeval tv;
        gettimeofday(&tv, nullptr);
        if (tv.tv_sec < 1700000000) return false;  // still 1970: NTP hasn't answered yet
        boot_epoch_ms = (int64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000 - (int64_t)millis();
    }
    time_t t = (time_t)((boot_epoch_ms + ms) / 1000);
    struct tm tm;
    gmtime_r(&t, &tm);
    strftime(out, len, "%Y-%m-%dT%H:%M:%SZ", &tm);
    return true;
}

static bool is_https()
{
    return strncmp(API_BASE_URL, "https://", 8) == 0;
}

// Prints mbedTLS's reason when an HTTPS connection fails, e.g. a certificate
// that does not chain to ca_certs.h, instead of HTTPClient's bare -1.
static void log_tls_error(int code)
{
    if (code >= 0 || !is_https()) return;
    char reason[120];
    int tls = secure_client.lastError(reason, sizeof(reason));
    Serial.printf("[net] request failed: %d (%s); TLS: %d %s\n",
                  code, HTTPClient::errorToString(code).c_str(), tls, tls ? reason : "none");
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
    log_tls_error(code);
    body_out = code > 0 ? http.getString() : String();
    http.end();  // with setReuse(true) this keeps the socket open for next time
    return code;
}

int net_get(const String &path, String &body_out)
{
    if (!net_connected()) return -100;
    if (is_https() && !net_clock_ready()) return -102;
    if (!open_request(path)) return -101;
    return finish_request(http.GET(), body_out);
}

int net_post(const String &path, const String &json_body, String &body_out)
{
    if (!net_connected()) return -100;
    if (is_https() && !net_clock_ready()) return -102;
    if (!open_request(path)) return -101;
    http.addHeader("Content-Type", "application/json");
    return finish_request(http.POST(json_body), body_out);
}

int net_download(const String &url, const char *dest_path)
{
    if (!net_connected()) return -100;
    if (url.startsWith("https://") && !net_clock_ready()) return -102;

    bool ok = url.startsWith("https://") ? http.begin(secure_client, url) : http.begin(plain_client, url);
    if (!ok) return -101;
    int code = http.GET();
    if (code != 200) {
        log_tls_error(code);
        http.end();
        return code;
    }

    String tmp = String(dest_path) + ".part";
    File f = FFat.open(tmp, FILE_WRITE);
    if (!f) {
        http.end();
        return -103;
    }
    int expected = http.getSize();
    int written = http.writeToStream(&f);
    f.close();
    http.end();

    if (written <= 0 || (expected > 0 && written != expected)) {
        FFat.remove(tmp);
        return -104;
    }
    FFat.remove(dest_path);
    FFat.rename(tmp, dest_path);
    return 200;
}
