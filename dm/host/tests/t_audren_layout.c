// The command header layout is taken from the first command list that walks in one, not from the first list generated.
// Mario Kart 8 Deluxe (SDK 4.4.0): the render thread generated a list before the game's first RequestUpdate whose third command was zeroed; taking the layout from it
// left the SDK 6 headers read in the newer layout, no DeviceSink was found and the game was silent. Lists here are built by hand in SDK 4.4.0's form.
#include "../hle.h"
#include <assert.h>
#include "../hle_audren.c"

void *guest_sym(const char *name) { (void)name; return NULL; }
void *objmap_get(const void *key) { (void)key; return NULL; }
void objmap_put(const void *key, void *value) { (void)key; (void)value; }
void *objmap_del(const void *key) { (void)key; return NULL; }
void *dm_guest_thread_spawn(void (*fn)(void *), void *arg, int prio, size_t stack) { (void)fn; (void)arg; (void)prio; (void)stack; return NULL; }
void dm_guest_thread_join(void *tt) { (void)tt; }
uint64_t now_ns(void) { return 0; }
void *dm_pcmout_open(int ch) { (void)ch; return NULL; }
void dm_pcmout_close(void *k) { (void)k; }
void dm_pcmout_start(void *k) { (void)k; }
int dm_pcmout_append(void *k, void *b) { (void)k; (void)b; return 0; }
void *dm_pcmout_released(void *k) { (void)k; return NULL; }
void dm_pcmout_wait(void *k, int ms) { (void)k; (void)ms; }
void hle_bind_system_event(void *ev, int ac) { (void)ev; (void)ac; }

enum { SAMPLES = 240, NMIX = 8, NCMD = 6 };
static int32_t mix[NMIX * SAMPLES];
static uint8_t list[0x20 + NCMD * 0x130];
// SDK 6 header: +0 magic, +4 size (s16), +6 command ID (s16), +0x10 enabled
static uint8_t *put(uint8_t *q, int id, int size) {
    memset(q, 0, (size_t)size);
    *(uint32_t *)q = 0xcafebabeu; *(int16_t *)(q + 4) = (int16_t)size; *(int16_t *)(q + 6) = (int16_t)id; q[0x10] = 1;
    return q + size;
}
// Five 0x40-byte commands of ID 6, then SDK 4's DeviceSink: ID 0xf, 0x130 bytes, inputs at +0x120 (count) and +0x124 (s8 indices), upsample buffer at +0x118
static size_t build(void) {
    memset(list, 0, sizeof list);
    *(uint32_t *)(list + 4) = NCMD; *(const int32_t **)(list + 8) = mix; *(uint32_t *)(list + 0x14) = SAMPLES; *(uint32_t *)(list + 0x18) = 48000;
    uint8_t *q = list + 0x20;
    for (int i = 0; i < NCMD - 1; i++) q = put(q, 6, 0x40);
    uint8_t *sink = q; q = put(q, 0xf, 0x130);
    *(uint32_t *)(sink + 0x120) = 2; sink[0x124] = 0; sink[0x125] = 1;
    return (size_t)(q - list);
}

int main(void) {
    for (int s = 0; s < SAMPLES; s++) { mix[s] = 1000; mix[SAMPLES + s] = -1000; }
    int16_t out[FRAME_MAX * 2];

    // The list generated before the first update: the third command zeroed, as Mario Kart 8 Deluxe's first list was
    size_t n = build();
    memset(list + 0x20 + 2 * 0x40, 0, 0x40);
    assert(capture(list, n, out) == 0);
    assert(!g_hdr6 && !g_hdr21 && !g_sink4);   // no layout taken from it

    // The next list walks in the SDK 6 layout: its one 0x130-byte command is the DeviceSink, and its two inputs come out as stereo
    n = build();
    int got = capture(list, n, out);
    assert(g_hdr6 && !g_hdr21 && g_sink4 && g_sink_id == 0xf);
    assert(got == SAMPLES && out[0] == 1000 && out[1] == -1000 && out[2 * SAMPLES - 2] == 1000);
    printf("audren layout: a list that walks in no layout is skipped; the next one gives the SDK 6 layout and SDK 4's DeviceSink\n");
    return 0;
}
