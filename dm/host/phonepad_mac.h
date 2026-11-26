// Phones as controllers over Wi-Fi (Mac only, phonepad_mac.m): DM_PHONE_PADS=1 (or =<port>, 8765 by default) serves a touch gamepad page on the local network; each phone that
// opens it is a controller of its own. The server only parses and keeps connections; the front end (front_mac.m) owns the player slots, so phones and physical controllers share them.
#pragma once
#include <stdint.h>

typedef struct {
    // Main queue. name: the phone's own id, kept across reconnects (its player comes back). Returns the player 0..DM_PLAYERS-1, or -1 when every player is taken
    int (*connected)(const void *owner, const char *name);
    // The phone's thread, so a touch is in the game before the next frame. player is what connected() returned. Sticks ±DM_STICK_MAX, y up
    void (*state)(const void *owner, int player, uint64_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry);
    void (*disconnected)(const void *owner);   // main queue; the owner pointer is not used again after this
    // The phone's thread. acc in G, (0, 0, -1) face up; rot in rad/s, the same frame as dm_motion_set. NULL if the phone sends no tilt
    void (*motion)(const void *owner, int player, const float acc[3], const float rot[3]);
    // Main queue. The phone asked to be player 1 now. Swap it with whoever holds that slot. *other is the phone that was player 1
    // (NULL when player 1 was empty or not a phone) and *other_at is the slot it moved to. Returns 0, or -1 when this phone holds no slot. NULL if unused.
    int (*claim_player1)(const void *owner, const void **other, int *other_at);
} phonepad_callbacks;

// Starts the server when DM_PHONE_PADS asks for it. Returns the address phones open ("https://192.168.1.20:8765"), or NULL when off or the port could not be opened.
// https so an iPhone will share its gyro (a page on plain http is not allowed to). The certificate is this Mac's own; the browser asks once.
const char *phonepad_start(phonepad_callbacks cb);

// The game's rumble for this phone's player, 0..1. The phone page turns it into a buzz. No-op while the server is off; owner is the pointer handed to connected()
void phonepad_rumble(const void *owner, float level);

// The monitor feed (GET /mon, the NX Pads app and /monitor) shows every player, not only phones: the front end reports its controllers and the keyboard here.
// kind: "pad" or "keys"; key: unique per source, no spaces. No-ops while the server is off
void phonepad_monitor(int player, const char *kind, const char *key, const char *name, uint64_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry);
void phonepad_monitor_gone(const char *key);
