// Phones as controllers over Wi-Fi (phonepad_mac.h). One TCP port answers: GET / the touch gamepad page (phonepad_page.html), GET /ws upgrades to a WebSocket that carries a
// phone's state, GET /monitor the dashboard page (phonepad_monitor.html), GET /mon the dashboard's WebSocket (also read by the NX Pads app, dm/mac/pads). No library: the HTTP
// request, the WebSocket handshake (RFC 6455, SHA-1 from CommonCrypto) and its frames are parsed here, one thread per connection.
// Phone → host text messages: "n <id>" once (the phone's random id from its localStorage), "m <name>" (the name the player typed; any time), "1" (become player 1 now, swapping with whoever has it), then "s <buttons> <lx> <ly> <rx> <ry>"
// on every change and at least every 100 ms (buttons in dm_input.h bit order, sticks ±32767 with y up), "g <ax> <ay> <az> <rx> <ry> <rz>" while tilt is on (G and rad/s, the
// controller frame dm_motion_set takes), "t <ms>" pings (echoed) and "r <ms>" its measured round trip.
// Host → phone: "p <player>" (1..8, 0 when every player is taken) and "h <level>" (0..1, the game's rumble for that player). A phone silent for 1.5 s counts as disconnected.
// Host → dashboard: "a <url>" (the address phones open) on connect, "u <player> <buttons> <lx> <ly> <rx> <ry> <rtt ms> <states/s> <kind> <key> <name…>" for every input source
// (kind phone, pad or keys; the last state of each live source is replayed to a dashboard that connects), "x <key>" when a source goes away. The dashboard sends "k" keepalives.
// Anyone on the local network can open the page: the server only runs while DM_PHONE_PADS asks for it.
#import <Foundation/Foundation.h>
#include "dm.h"
#include "dm_input.h"
#include "phonepad_mac.h"
#import <Network/Network.h>
#include <CommonCrypto/CommonDigest.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <libproc.h>
#include <math.h>
#include <signal.h>
#include <net/if.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wc23-extensions"
static const char PAGE[] = {
#embed "phonepad_page.html"
, 0 };
static const char MONITOR[] = {
#embed "phonepad_monitor.html"
, 0 };
#pragma clang diagnostic pop

static phonepad_callbacks g_cb;
static int g_on, g_tls;
static char g_url[96];
static sec_identity_t g_sec;
static dispatch_queue_t g_q;
static nw_listener_t g_listener;

// One connection. Bytes arrive on the network queue and the phone's thread waits for them; a dashboard write does not wait, so it cannot stall the game.
typedef struct {
    nw_connection_t nw; pthread_mutex_t mu; pthread_cond_t cv;
    char *in; size_t in_len, in_cap; int eof, dead, refs, wait_ms;
    int mon_out, mon_catchup, mon_i, mon_again, mon_xn;   // one dashboard frame in flight; newer states wait and go out as the latest, not a replay
    char mon_x[4][48];
} conn;

typedef struct {
    conn *io; int player; char id[24]; char name[64]; char nick[48]; float rtt; int count, hz; double win;
    float rumble; unsigned rumble_seq, rumble_sent; pthread_mutex_t mu;
} phone;

// Dashboards and the last state of every source, under one lock: a dashboard that connects gets the address and every source at once, then each change as it comes
#define MON_MAX 16
#define SRC_MAX 32
static pthread_mutex_t g_mon_lock = PTHREAD_MUTEX_INITIALIZER;
static conn *g_mon[MON_MAX];
static int g_nmon;
static struct { char key[48]; char msg[240]; } g_src[SRC_MAX];
static int g_nsrc;
static void conn_release(conn *c);
static void mon_send_locked(conn *c, const char *s);
static int mon_live_locked(conn *c) { for (int i = 0; i < g_nmon; i++) if (g_mon[i] == c) return 1; return 0; }
static void mon_pump_locked(conn *c) {   // g_mon_lock held, nothing in flight: a removal, then the next saved state
    if (!mon_live_locked(c) || c->mon_out) return;
    if (c->mon_xn) {
        char m[64]; snprintf(m, sizeof m, "x %s", c->mon_x[0]);
        memmove(c->mon_x[0], c->mon_x[1], (size_t)(--c->mon_xn) * sizeof c->mon_x[0]);
        mon_send_locked(c, m); return;
    }
    if (!c->mon_catchup) return;
    if (c->mon_i < g_nsrc) { mon_send_locked(c, g_src[c->mon_i++].msg); return; }
    c->mon_catchup = 0; c->mon_i = 0;
    if (c->mon_again && g_nsrc) { c->mon_again = 0; c->mon_catchup = 1; mon_send_locked(c, g_src[c->mon_i++].msg); }
}
static void mon_send_locked(conn *c, const char *s) {   // one frame in flight: a slow dashboard gets the newest state, not a queue of old moves
    size_t n = strlen(s); unsigned char f[4 + 256]; size_t hn;
    if (!c->nw || n > 255) return;
    if (c->mon_out) {
        if (s[0] == 'u') c->mon_again = 1;
        else if (s[0] == 'x' && s[1] == ' ' && c->mon_xn < 4) snprintf(c->mon_x[c->mon_xn++], sizeof c->mon_x[0], "%s", s + 2);
        return;
    }
    f[0] = 0x81; if (n < 126) { f[1] = (unsigned char)n; hn = 2; } else { f[1] = 126; f[2] = 0; f[3] = (unsigned char)n; hn = 4; }
    memcpy(f + hn, s, n);
    void *copy = malloc(hn + n); if (!copy) return;
    memcpy(copy, f, hn + n);
    dispatch_data_t data = dispatch_data_create(copy, hn + n, NULL, DISPATCH_DATA_DESTRUCTOR_FREE);
    pthread_mutex_lock(&c->mu); c->refs++; pthread_mutex_unlock(&c->mu);
    c->mon_out = 1;
    nw_connection_send(c->nw, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, false, ^(nw_error_t error) {
        if (error) { pthread_mutex_lock(&c->mu); c->eof = 1; pthread_cond_broadcast(&c->cv); pthread_mutex_unlock(&c->mu); }
        dispatch_async(g_q, ^{   // not inline: mon_send_locked may be holding g_mon_lock on this thread
            pthread_mutex_lock(&g_mon_lock);
            c->mon_out = 0;
            if (c->mon_again && !c->mon_catchup) { c->mon_again = 0; c->mon_catchup = 1; c->mon_i = 0; }
            mon_pump_locked(c);
            pthread_mutex_unlock(&g_mon_lock);
            conn_release(c);
        });
    });
}
static void mon_update(const char *key, const char *msg) {
    pthread_mutex_lock(&g_mon_lock);
    int i = 0; while (i < g_nsrc && strcmp(g_src[i].key, key)) i++;
    if (i == g_nsrc && g_nsrc < SRC_MAX) { g_nsrc++; snprintf(g_src[i].key, sizeof g_src[i].key, "%s", key); }
    if (i < g_nsrc) snprintf(g_src[i].msg, sizeof g_src[i].msg, "%s", msg);
    for (int m = 0; m < g_nmon; m++) mon_send_locked(g_mon[m], msg);
    pthread_mutex_unlock(&g_mon_lock);
}
static void mon_remove(const char *key) {
    pthread_mutex_lock(&g_mon_lock);
    for (int i = 0; i < g_nsrc; i++) if (!strcmp(g_src[i].key, key)) { g_src[i] = g_src[--g_nsrc]; break; }
    char m[64]; snprintf(m, sizeof m, "x %s", key);
    for (int k = 0; k < g_nmon; k++) mon_send_locked(g_mon[k], m);
    pthread_mutex_unlock(&g_mon_lock);
}
static void mon_state(int player, const char *kind, const char *key, const char *name, uint64_t b, int lx, int ly, int rx, int ry, float rtt, int hz) {
    char m[240]; snprintf(m, sizeof m, "u %d %llu %d %d %d %d %.1f %d %s %s %s", player + 1, (unsigned long long)(b & 0xffff), lx, ly, rx, ry, rtt, hz, kind, key, name);
    mon_update(key, m);
}
void phonepad_monitor(int player, const char *kind, const char *key, const char *name, uint64_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry) {
    if (g_on && player >= 0) mon_state(player, kind, key, name, buttons, lx, ly, rx, ry, 0, 0);
}
void phonepad_monitor_gone(const char *key) { if (g_on) mon_remove(key); }
static void phone_key(const phone *ph, char *out, size_t cap) { snprintf(out, cap, "ph-%s", ph->id); }
static void phone_report(const phone *ph, uint64_t b, int lx, int ly, int rx, int ry) {
    char key[48]; phone_key(ph, key, sizeof key);
    char shown[64]; if (ph->nick[0]) snprintf(shown, sizeof shown, "%s", ph->nick); else snprintf(shown, sizeof shown, "Phone %s", ph->id);
    mon_state(ph->player, "phone", key, shown, b, lx, ly, rx, ry, ph->rtt, ph->hz);
}

static void deadline(struct timespec *ts, int ms) {
    clock_gettime(CLOCK_REALTIME, ts);
    ts->tv_sec += ms / 1000; ts->tv_nsec += (long)(ms % 1000) * 1000000L;
    if (ts->tv_nsec >= 1000000000L) { ts->tv_sec++; ts->tv_nsec -= 1000000000L; }
}
static void buf_add(conn *c, const void *p, size_t n) {   // c->mu held
    if (c->in_len + n > c->in_cap) {
        size_t cap = c->in_cap ? c->in_cap * 2 : 4096; while (cap < c->in_len + n) cap *= 2;
        char *b = realloc(c->in, cap); if (!b) { c->eof = 1; return; }
        c->in = b; c->in_cap = cap;
    }
    memcpy(c->in + c->in_len, p, n); c->in_len += n;
}
static void conn_release(conn *c) {
    pthread_mutex_lock(&c->mu); int left = --c->refs; pthread_mutex_unlock(&c->mu);
    if (left) return;
    if (c->nw) CFRelease((__bridge CFTypeRef)c->nw);
    pthread_mutex_destroy(&c->mu); pthread_cond_destroy(&c->cv); free(c->in); free(c);
}
static void arm_recv(conn *c) {
    pthread_mutex_lock(&c->mu);
    if (c->dead || c->eof) { pthread_mutex_unlock(&c->mu); return; }
    c->refs++;
    pthread_mutex_unlock(&c->mu);
    nw_connection_receive(c->nw, 1, 16384, ^(dispatch_data_t content, nw_content_context_t context, bool done, nw_error_t error) {
        (void)context;
        pthread_mutex_lock(&c->mu);
        if (content && !c->dead) dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset, const void *bytes, size_t size) {
            (void)region; (void)offset; buf_add(c, bytes, size); return true;
        });
        if (done || error) c->eof = 1;
        pthread_cond_broadcast(&c->cv);
        pthread_mutex_unlock(&c->mu);
        if (!done && !error) arm_recv(c);
        conn_release(c);
    });
}
static void link_free(conn *c) {
    if (!c) return;
    pthread_mutex_lock(&c->mu); c->dead = 1; c->eof = 1; nw_connection_t nw = c->nw; pthread_cond_broadcast(&c->cv); pthread_mutex_unlock(&c->mu);
    if (nw) nw_connection_cancel(nw);
    conn_release(c);
}
// The certificate is remembered per address, so a phone trusts this Mac once instead of on every launch
static int tls_prepare(const char *ip) {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/nxnative/phonepad"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *p12 = [dir stringByAppendingPathComponent:@"cert.p12"], *ipf = [dir stringByAppendingPathComponent:@"ip"];
    NSString *have = [NSString stringWithContentsOfFile:ipf encoding:NSUTF8StringEncoding error:nil];
    if (![have isEqualToString:@(ip)] || ![[NSFileManager defaultManager] fileExistsAtPath:p12]) {
        NSString *san = strcmp(ip, "localhost") ? [NSString stringWithFormat:@"IP:%s,IP:127.0.0.1,DNS:localhost", ip] : @"DNS:localhost,IP:127.0.0.1";
        NSString *conf = [NSString stringWithFormat:@"[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=nxpad\n[v3]\nsubjectAltName=%@\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n", san];
        NSString *cnf = [dir stringByAppendingPathComponent:@"cert.cnf"], *key = [dir stringByAppendingPathComponent:@"key.pem"], *crt = [dir stringByAppendingPathComponent:@"cert.pem"];
        if (![conf writeToFile:cnf atomically:YES encoding:NSUTF8StringEncoding error:nil]) return -1;
        NSTask *req = [NSTask new]; req.executableURL = [NSURL fileURLWithPath:@"/usr/bin/openssl"];
        req.arguments = @[@"req", @"-x509", @"-newkey", @"rsa:2048", @"-keyout", key, @"-out", crt, @"-days", @"800", @"-nodes", @"-config", cnf, @"-extensions", @"v3"];
        req.standardOutput = [NSFileHandle fileHandleWithNullDevice]; req.standardError = [NSFileHandle fileHandleWithNullDevice];
        if (![req launchAndReturnError:nil]) return -1; [req waitUntilExit]; if (req.terminationStatus) return -1;
        NSTask *pack = [NSTask new]; pack.executableURL = [NSURL fileURLWithPath:@"/usr/bin/openssl"];
        pack.arguments = @[@"pkcs12", @"-export", @"-inkey", key, @"-in", crt, @"-out", p12, @"-passout", @"pass:nxpad"];
        pack.standardOutput = [NSFileHandle fileHandleWithNullDevice]; pack.standardError = [NSFileHandle fileHandleWithNullDevice];
        if (![pack launchAndReturnError:nil]) return -1; [pack waitUntilExit]; if (pack.terminationStatus) return -1;
        [[NSFileManager defaultManager] removeItemAtPath:key error:nil]; [[NSFileManager defaultManager] removeItemAtPath:crt error:nil];
        [@(ip) writeToFile:ipf atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    NSData *data = [NSData dataWithContentsOfFile:p12]; if (!data) return -1;
    // In memory only: a key imported into the login keychain belongs to the binary that imported it, and every other or rebuilt binary (a game, NX Pads' stand-in)
    // then waits on a hidden keychain prompt in the middle of each phone's TLS handshake
    NSMutableDictionary *opt = [@{(id)kSecImportExportPassphrase: @"nxpad"} mutableCopy]; CFArrayRef items = NULL;
    if (@available(macOS 15.0, *)) opt[(id)kSecImportToMemoryOnly] = @YES;
    if (SecPKCS12Import((__bridge CFDataRef)data, (__bridge CFDictionaryRef)opt, &items) || !items || !CFArrayGetCount(items)) return -1;
    NSDictionary *item = CFArrayGetValueAtIndex(items, 0);
    SecIdentityRef ident = (__bridge SecIdentityRef)item[(id)kSecImportItemIdentity]; if (!ident) { CFRelease(items); return -1; }
    SecKeyRef key = NULL; OSStatus ks = SecIdentityCopyPrivateKey(ident, &key);
    if (ks || !key) { LOG("phone pads: certificate has no private key (%d)", (int)ks); CFRelease(items); return -1; }
    CFRelease(key);
    g_sec = sec_identity_create(ident); CFRelease(items);
    return g_sec ? 0 : -1;
}
static int send_all(conn *c, const void *p, size_t n) {
    if (!n) return 0;
    void *copy = malloc(n); if (!copy) return -1;
    memcpy(copy, p, n);
    dispatch_data_t data = dispatch_data_create(copy, n, NULL, DISPATCH_DATA_DESTRUCTOR_FREE);
    __block int done = 0, bad = 0;
    nw_connection_send(c->nw, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, false, ^(nw_error_t error) {
        pthread_mutex_lock(&c->mu); done = 1; bad = error != NULL; pthread_cond_broadcast(&c->cv); pthread_mutex_unlock(&c->mu);
    });
    pthread_mutex_lock(&c->mu);
    struct timespec ts; deadline(&ts, c->wait_ms);
    while (!done && !c->eof) if (pthread_cond_timedwait(&c->cv, &c->mu, &ts)) { bad = 1; break; }
    pthread_mutex_unlock(&c->mu);
    return bad ? -1 : 0;
}
static int recv_all(conn *c, void *p, size_t n) {
    char *b = p;
    pthread_mutex_lock(&c->mu);
    struct timespec ts; deadline(&ts, c->wait_ms);
    while (n) {
        if (!c->in_len) {
            if (c->eof || pthread_cond_timedwait(&c->cv, &c->mu, &ts)) { pthread_mutex_unlock(&c->mu); return -1; }
            continue;
        }
        size_t r = c->in_len < n ? c->in_len : n;
        memcpy(b, c->in, r); memmove(c->in, c->in + r, c->in_len - r); c->in_len -= r; b += r; n -= r;
    }
    pthread_mutex_unlock(&c->mu);
    return 0;
}
static int recv_some(conn *c, void *p, size_t cap, size_t *got) {   // one chunk of the HTTP request, before it is a WebSocket
    pthread_mutex_lock(&c->mu);
    struct timespec ts; deadline(&ts, c->wait_ms);
    while (!c->in_len && !c->eof) if (pthread_cond_timedwait(&c->cv, &c->mu, &ts)) break;
    if (!c->in_len) { pthread_mutex_unlock(&c->mu); return -1; }
    size_t r = c->in_len < cap ? c->in_len : cap;
    memcpy(p, c->in, r); memmove(c->in, c->in + r, c->in_len - r); c->in_len -= r;
    pthread_mutex_unlock(&c->mu);
    *got = r; return 0;
}
static void ws_send_text(conn *c, const char *s) {
    size_t n = strlen(s); unsigned char h[2] = {0x81, (unsigned char)n};   // host messages to a phone stay under 126 bytes
    if (n < 126 && !send_all(c, h, 2)) send_all(c, s, n);
}
// One frame's payload into buf (NUL-terminated). Returns the opcode, or -1 when the connection ended, timed out or broke the protocol
static int ws_read(conn *c, char *buf, size_t cap, size_t *len) {
    unsigned char h[2], mask[4]; if (recv_all(c, h, 2)) return -1;
    int op = h[0] & 15; uint64_t n = h[1] & 127;
    if (n == 126) { unsigned char e[2]; if (recv_all(c, e, 2)) return -1; n = (uint64_t)e[0] << 8 | e[1]; }
    else if (n == 127) return -1;   // the page never sends that much
    if (!(h[1] & 128) || n >= cap) return -1;   // a client's frames are always masked
    if (recv_all(c, mask, 4) || recv_all(c, buf, (size_t)n)) return -1;
    for (uint64_t i = 0; i < n; i++) buf[i] ^= mask[i & 3];
    buf[n] = 0; *len = (size_t)n;
    return op;
}
static void http_send(conn *c, const char *status, const char *type, const char *body, size_t n) {
    char h[256]; int k = snprintf(h, sizeof h, "HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", status, type, n);
    if (!send_all(c, h, (size_t)k)) send_all(c, body, n);
}
static const char *header(const char *req, const char *name) {   // the value after "name:" in the request's header lines (case-insensitive), or NULL
    size_t n = strlen(name);
    for (const char *l = strstr(req, "\r\n"); l && l[2] && !(l[2] == '\r' && l[3] == '\n'); l = strstr(l + 2, "\r\n"))
        if (!strncasecmp(l + 2, name, n) && l[2 + n] == ':') { const char *v = l + 3 + n; while (*v == ' ') v++; return v; }
    return NULL;
}
static void clean_text(char *dst, size_t cap, const char *src) {   // printable ASCII and UTF-8 bytes only; a name is the last field of a dashboard line, so spaces may stay
    size_t o = 0;
    for (const unsigned char *s = (const unsigned char *)src; *s && o + 1 < cap; s++) if (*s >= 0x20 && *s != 0x7f) dst[o++] = (char)*s;
    while (o && (dst[o - 1] & 0xc0) == 0x80) o--;   // a UTF-8 sequence cut by the limit
    if (o && (unsigned char)dst[o - 1] >= 0xc0) o--;
    dst[o] = 0;
}

void phonepad_rumble(const void *owner, float level) {
    if (!g_on || !owner) return;
    if (level < 0) level = 0; if (level > 1) level = 1;
    phone *ph = (phone *)owner;
    pthread_mutex_lock(&ph->mu);
    if (fabsf(ph->rumble - level) >= 0.04f || (level == 0 && ph->rumble != 0)) { ph->rumble = level; ph->rumble_seq++; }
    pthread_mutex_unlock(&ph->mu);
}
static void flush_rumble(conn *c, phone *ph) {
    float level; int send;
    pthread_mutex_lock(&ph->mu);
    send = ph->rumble_seq != ph->rumble_sent; level = ph->rumble; if (send) ph->rumble_sent = ph->rumble_seq;
    pthread_mutex_unlock(&ph->mu);
    if (!send) return;
    char m[32]; snprintf(m, sizeof m, "h %.2f", level); ws_send_text(c, m);
}
static void phone_session(conn *c) {
    char key[64]; const char *k = NULL; int mon;
    {
        char req[8192]; size_t n = 0;
        while (n < sizeof req - 1) {
            size_t got = 0; if (recv_some(c, req + n, sizeof req - 1 - n, &got)) return;
            n += got; req[n] = 0; if (strstr(req, "\r\n\r\n")) break;
        }
        if (strncmp(req, "GET ", 4)) { http_send(c, "405 Method Not Allowed", "text/plain", "", 0); return; }
        int ws = !strncmp(req + 4, "/ws ", 4);
        mon = !strncmp(req + 4, "/mon ", 5);
        if (!ws && !mon) {
            if (!strncmp(req + 4, "/ ", 2) || !strncmp(req + 4, "/?", 2)) http_send(c, "200 OK", "text/html; charset=utf-8", PAGE, sizeof PAGE - 1);
            else if (!strncmp(req + 4, "/monitor", 8)) http_send(c, "200 OK", "text/html; charset=utf-8", MONITOR, sizeof MONITOR - 1);
            else http_send(c, "404 Not Found", "text/plain", "", 0);
            return;
        }
        k = header(req, "Sec-WebSocket-Key"); if (!k) { http_send(c, "400 Bad Request", "text/plain", "", 0); return; }
        size_t kn = strcspn(k, "\r\n"); if (kn >= sizeof key) return;
        memcpy(key, k, kn); key[kn] = 0;
    }
    NSString *acc; {
        NSString *s = [@(key) stringByAppendingString:@"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"];
        unsigned char d[CC_SHA1_DIGEST_LENGTH]; NSData *in = [s dataUsingEncoding:NSUTF8StringEncoding];
        CC_SHA1(in.bytes, (CC_LONG)in.length, d);
        acc = [[NSData dataWithBytes:d length:sizeof d] base64EncodedStringWithOptions:0];
    }
    char h[256]; int hn = snprintf(h, sizeof h, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", acc.UTF8String);
    if (send_all(c, h, (size_t)hn)) return;
    c->wait_ms = 1500;   // past the first request a silent phone is gone; that first request may wait on a certificate warning
    char buf[512]; size_t len;

    if (mon) {   // a dashboard: the address and every live source now, then changes through mon_update; it only sends keepalives
        pthread_mutex_lock(&g_mon_lock);
        int ok = g_nmon < MON_MAX;
        if (ok) {
            g_mon[g_nmon++] = c;
            char a[128]; snprintf(a, sizeof a, "a %s", g_url); mon_send_locked(c, a);
            for (int i = 0; i < g_nsrc; i++) mon_send_locked(c, g_src[i].msg);
        }
        pthread_mutex_unlock(&g_mon_lock);
        if (!ok) return;
        for (int op; (op = ws_read(c, buf, sizeof buf, &len)) >= 0 && op != 8;) {}
        pthread_mutex_lock(&g_mon_lock);
        for (int i = 0; i < g_nmon; i++) if (g_mon[i] == c) { g_mon[i] = g_mon[--g_nmon]; break; }
        pthread_mutex_unlock(&g_mon_lock);
        return;
    }

    phone *ph = calloc(1, sizeof *ph); ph->io = c; ph->player = -2;   // -2: no id yet
    pthread_mutex_init(&ph->mu, NULL);
    ph->win = CFAbsoluteTimeGetCurrent();
    uint64_t lb = 0; int llx = 0, lly = 0, lrx = 0, lry = 0;
    for (;;) {
        int op = ws_read(c, buf, sizeof buf, &len);
        if (op < 0 || op == 8) break;
        if (op == 9) { unsigned char pong[2] = {0x8a, 0}; send_all(c, pong, 2); continue; }
        if (op != 1) continue;
        if (buf[0] == 't' && buf[1] == ' ') { ws_send_text(c, buf); continue; }   // the page's ping: echoed at once, so its round trip is the network's
        if (buf[0] == 'r' && buf[1] == ' ') { ph->rtt = strtof(buf + 2, NULL); continue; }
        if (buf[0] == 'm' && buf[1] == ' ') { clean_text(ph->nick, sizeof ph->nick, buf + 2); if (ph->player >= 0) phone_report(ph, lb, llx, lly, lrx, lry); continue; }
        if (buf[0] == '1' && buf[1] == 0 && ph->player >= 0 && g_cb.claim_player1) {
            __block int np = -1, op = -1; __block const void *other = NULL;
            dispatch_sync(dispatch_get_main_queue(), ^{
                np = g_cb.claim_player1(ph, &other, &op);
                if (np < 0) return;
                ph->player = np;
                char m[16]; snprintf(m, sizeof m, "p %d", np + 1); ws_send_text(c, m);
                if (other && other != ph && op >= 0) {
                    phone *o = (phone *)other; o->player = op;
                    char m2[16]; snprintf(m2, sizeof m2, "p %d", op + 1);
                    if (o->io) ws_send_text(o->io, m2);
                }
            });
            continue;
        }
        if (buf[0] == 'n' && buf[1] == ' ' && ph->player == -2) {
            size_t o = 0; for (const char *s = buf + 2; *s && o + 1 < sizeof ph->id; s++) if ((*s >= 'a' && *s <= 'z') || (*s >= '0' && *s <= '9')) ph->id[o++] = *s;
            ph->id[o] = 0; if (!o) break;
            snprintf(ph->name, sizeof ph->name, "phone %s", ph->id); const char *name = ph->name;
            __block int p; dispatch_sync(dispatch_get_main_queue(), ^{ p = g_cb.connected(ph, name); });
            ph->player = p; char m[16]; snprintf(m, sizeof m, "p %d", p + 1); ws_send_text(c, m);
            if (p >= 0) phone_report(ph, 0, 0, 0, 0, 0);
            continue;
        }
        unsigned long long b; int lx, ly, rx, ry;
        float acc[3], rot[3];
        int nf = sscanf(buf, "s %llu %d %d %d %d %f %f %f %f %f %f", &b, &lx, &ly, &rx, &ry, &acc[0], &acc[1], &acc[2], &rot[0], &rot[1], &rot[2]);
        if (ph->player >= 0 && (nf == 5 || nf == 11)) {
            uint64_t bb = b & 0xffff;
            ph->count++; double now = CFAbsoluteTimeGetCurrent();
            if (now - ph->win >= 1) { ph->hz = (int)(ph->count / (now - ph->win) + 0.5); ph->count = 0; ph->win = now; }
            lb = bb; llx = lx; lly = ly; lrx = rx; lry = ry;
            g_cb.state(ph, ph->player, bb, lx, ly, rx, ry);   // before the dashboard: the game samples this, the dashboard only watches
            if (nf == 11 && g_cb.motion) g_cb.motion(ph, ph->player, acc, rot);
            flush_rumble(c, ph);
            phone_report(ph, bb, lx, ly, rx, ry);
        }
    }
    if (ph->player == -2) { pthread_mutex_destroy(&ph->mu); free(ph); return; }
    if (ph->player >= 0) { char key[48]; phone_key(ph, key, sizeof key); mon_remove(key); }
    dispatch_async(dispatch_get_main_queue(), ^{ g_cb.disconnected(ph); pthread_mutex_destroy(&ph->mu); free(ph); });
}
static void *phone_thread(void *arg) {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);   // a late phone thread is late input; the game's work must not queue ahead of it
    conn *c = arg;
    @autoreleasepool { phone_session(c); }
    link_free(c);
    return NULL;
}
static void new_connection(nw_connection_t connection) {
    conn *c = calloc(1, sizeof *c); if (!c) { nw_connection_cancel(connection); return; }
    c->nw = (__bridge nw_connection_t)CFBridgingRetain(connection); c->refs = 2; c->wait_ms = 15000;   // the phone's thread and the state handler, which runs until cancelled
    pthread_mutex_init(&c->mu, NULL); pthread_cond_init(&c->cv, NULL);
    nw_connection_set_queue(connection, g_q);
    nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error) {
        (void)error;
        if (state != nw_connection_state_failed && state != nw_connection_state_cancelled) return;
        pthread_mutex_lock(&c->mu); c->eof = 1; pthread_cond_broadcast(&c->cv); pthread_mutex_unlock(&c->mu);
        if (state == nw_connection_state_cancelled) conn_release(c);
    });
    nw_connection_start(connection);
    arm_recv(c);
    pthread_t th; if (pthread_create(&th, NULL, phone_thread, c)) link_free(c); else pthread_detach(th);
}
static void lan_address(char *out, size_t cap) {   // the first IPv4 address of an interface that is up and not loopback (Wi-Fi or Ethernet), "localhost" with none
    snprintf(out, cap, "localhost");
    struct ifaddrs *a; if (getifaddrs(&a)) return;
    for (struct ifaddrs *i = a; i; i = i->ifa_next)
        if (i->ifa_addr && i->ifa_addr->sa_family == AF_INET && (i->ifa_flags & IFF_UP) && !(i->ifa_flags & IFF_LOOPBACK) && !strncmp(i->ifa_name, "en", 2)) {
            inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr, out, (socklen_t)cap); break;
        }
    freeifaddrs(a);
}

static void lobby_stop(void) {   // NX Pads' stand-in server (phonepad_lobby.m) holds the port while no game runs; a game takes it over and the phones reconnect to the game
    char path[1024]; snprintf(path, sizeof path, "%s/Library/Application Support/nxnative/phonepad/lobby.pid", getenv("HOME") ? getenv("HOME") : "");
    FILE *f = fopen(path, "r"); if (!f) return;
    int pid = 0; if (fscanf(f, "%d", &pid) != 1) pid = 0;
    fclose(f);
    char name[64] = "";
    if (pid <= 0 || pid == getpid() || proc_name(pid, name, sizeof name) <= 0 || strcmp(name, "nxpadlobby")) return;
    kill(pid, SIGTERM);
    for (int i = 0; i < 100 && proc_name(pid, name, sizeof name) > 0; i++) usleep(10000);
    LOG("phone pads: took the port over from NX Pads' stand-in; connected phones move to the game");
}

const char *phonepad_start(phonepad_callbacks cb) {
    const char *e = getenv("DM_PHONE_PADS"); if (!e || !*e || !strcmp(e, "0")) return NULL;
    int port = atoi(e); if (port <= 1 || port > 65535) port = 8765;
    lobby_stop();
    g_cb = cb;
    char ip[64]; lan_address(ip, sizeof ip);
    g_tls = tls_prepare(ip) == 0;
    if (!g_tls) LOG("[RED] phone pads: certificate failed, serving http (an iPhone will not share its gyro)");
    snprintf(g_url, sizeof g_url, "%s://%s:%d", g_tls ? "https" : "http", ip, port);
    g_q = dispatch_queue_create("nx.phonepad", DISPATCH_QUEUE_CONCURRENT);
    dispatch_set_target_queue(g_q, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
    char ps[8]; snprintf(ps, sizeof ps, "%d", port);
    nw_parameters_t params = g_tls ? nw_parameters_create_secure_tcp(^(nw_protocol_options_t opts) {
        sec_protocol_options_t sec = nw_tls_copy_sec_protocol_options(opts);
        sec_protocol_options_set_local_identity(sec, g_sec);
    }, ^(nw_protocol_options_t opts) { nw_tcp_options_set_no_delay(opts, true); }) : nw_parameters_create();
    nw_parameters_set_service_class(params, nw_service_class_responsive_data);   // small packets, delivered now: a controller, not a download
    nw_listener_t listener = nw_listener_create_with_port(ps, params);
    g_listener = (__bridge nw_listener_t)CFBridgingRetain(listener);
    if (!listener) { LOG("[RED] phone pads: port %d could not be opened (DM_PHONE_PADS)", port); return NULL; }
    dispatch_semaphore_t ready = dispatch_semaphore_create(0); __block int up = 0;
    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t error) {
        (void)error;
        if (state == nw_listener_state_ready) { up = 1; dispatch_semaphore_signal(ready); }
        else if (state == nw_listener_state_failed) dispatch_semaphore_signal(ready);
    });
    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection) { new_connection(connection); });
    nw_listener_set_queue(listener, g_q);
    nw_listener_start(listener);
    dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    if (!up) { LOG("[RED] phone pads: port %d could not be opened (DM_PHONE_PADS)", port); nw_listener_cancel(listener); return NULL; }
    g_on = 1;
    LOG("phone pads: open %s on a phone on this Wi-Fi; each phone is a controller of its own (DM_PHONE_PADS); the NX Pads app or %s/monitor shows every player", g_url, g_url);
    return g_url;
}
