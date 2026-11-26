// nxpadlobby: the phone pad server (phonepad_mac.m) with no game, started by NX Pads (dm/mac/pads) while no game is serving, so phones connect and can be tried out before a game starts.
// A game that starts takes the port over: its phonepad_start ends this process (pid in phonepad/lobby.pid) and the phones reconnect to the game on their own.
#import <Foundation/Foundation.h>
#include "dm_input.h"
#include "phonepad_mac.h"
#include <libproc.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const void *g_owner[DM_PLAYERS];
static char g_name[DM_PLAYERS][64];   // kept after a phone leaves, so it gets the same player back
static char g_pid[1024];

static int connected(const void *owner, const char *name) {
    int p = -1;
    for (int i = 0; i < DM_PLAYERS && p < 0; i++) if (!strcmp(g_name[i], name)) p = i;
    for (int i = 0; i < DM_PLAYERS && p < 0; i++) if (!g_owner[i] && !g_name[i][0]) p = i;
    for (int i = 0; i < DM_PLAYERS && p < 0; i++) if (!g_owner[i]) p = i;
    if (p < 0) return -1;
    g_owner[p] = owner; snprintf(g_name[p], sizeof g_name[p], "%s", name);
    return p;
}
static void state(const void *owner, int player, uint64_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry) {
    (void)owner; (void)player; (void)buttons; (void)lx; (void)ly; (void)rx; (void)ry;
}
static void disconnected(const void *owner) { for (int i = 0; i < DM_PLAYERS; i++) if (g_owner[i] == owner) g_owner[i] = NULL; }
static int claim(const void *owner, const void **other, int *other_at) {
    *other = NULL; *other_at = -1;
    int mine = -1;
    for (int i = 0; i < DM_PLAYERS; i++) if (g_owner[i] == owner) mine = i;
    if (mine < 0) return -1;
    if (mine == 0) return 0;
    const void *was = g_owner[0];
    char tmp[64];
    memcpy(tmp, g_name[0], sizeof tmp);
    memcpy(g_name[0], g_name[mine], sizeof tmp);
    memcpy(g_name[mine], tmp, sizeof tmp);
    g_owner[0] = owner; g_owner[mine] = was;
    if (was) { *other = was; *other_at = mine; }
    return 0;
}
static void motion(const void *owner, int player, const float acc[3], const float rot[3]) { (void)owner; (void)player; (void)acc; (void)rot; }

static int game_running(void) {   // a game (dmhost) that is starting owns the port, even before it opens it
    int n = proc_listallpids(NULL, 0); if (n <= 0) return 0;
    pid_t *pids = calloc((size_t)n + 64, sizeof *pids); n = proc_listallpids(pids, (int)(((size_t)n + 64) * sizeof *pids));
    int found = 0; char name[64];
    for (int i = 0; i < n && !found; i++) if (pids[i] > 0 && proc_name(pids[i], name, sizeof name) > 0 && !strcmp(name, "dmhost")) found = 1;
    free(pids); return found;
}

int main(void) {
    @autoreleasepool {
        setenv("DM_PHONE_PADS", "1", 0);
        signal(SIGPIPE, SIG_IGN);
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/nxnative/phonepad"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        snprintf(g_pid, sizeof g_pid, "%s/lobby.pid", dir.fileSystemRepresentation);
        if (game_running()) return 1;
        if (!phonepad_start((phonepad_callbacks){connected, state, disconnected, motion, claim})) return 1;   // a game already has the port
        FILE *f = fopen(g_pid, "w"); if (f) { fprintf(f, "%d\n", getpid()); fclose(f); }
        signal(SIGTERM, SIG_IGN);
        dispatch_source_t term = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(term, ^{ unlink(g_pid); _exit(0); });
        dispatch_resume(term);
        pid_t parent = getppid();   // NX Pads: the stand-in ends with it, also when it crashes
        dispatch_source_t gone = parent > 1 ? dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)parent, DISPATCH_PROC_EXIT, dispatch_get_main_queue()) : NULL;
        if (gone) { dispatch_source_set_event_handler(gone, ^{ unlink(g_pid); _exit(0); }); dispatch_resume(gone); }
        CFRunLoopRun();
    }
}
