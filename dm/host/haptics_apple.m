// Core Haptics adapts the game's bands; it cannot reproduce the Switch's exact waveforms.
// All engines and players belong to one serial queue. Guest threads enqueue ordered snapshots only.
#import "haptics_apple.h"
#import <CoreHaptics/CoreHaptics.h>
#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#import <AVFAudio/AVFAudio.h>
#else
#import <AppKit/AppKit.h>
#endif
#include <math.h>
#include <pthread.h>
#include <time.h>

@interface DmRumbleChannel : NSObject
@property(nonatomic) CHHapticEngine *engine;
@property(nonatomic) id<CHHapticPatternPlayer> pattern;
@property(nonatomic, copy) CHHapticEngine *(^createEngine)(NSError **);
@property(nonatomic, copy) NSString *target;
@property(nonatomic, copy) void (^fallback)(NSTimeInterval);
@property(nonatomic) int player;
@property(nonatomic) int motor;   // the game's motor it plays (0 left, 1 right), or -1 for both mixed
@property(nonatomic, copy) void (^merge)(void);   // replaces a split route by one engine for both motors
@property(nonatomic) uint64_t generation;
@property(nonatomic) uint64_t silenceGeneration;
@property(nonatomic) NSTimeInterval retryAfter;
@property(nonatomic) unsigned failures;
@property(nonatomic) BOOL simple;   // the engine's server offers no advanced players: plain players play the effect in pulses
@property(nonatomic) id<CHHapticPatternPlayer> previous;   // the pulse before the scheduled one, still playing
@property(nonatomic) NSTimeInterval pulseEnd;   // engine time at which the last scheduled pulse ends
@property(nonatomic) dm_haptic_level level;   // the level the next pulse starts at
- (void)apply:(dm_haptic_level)level;
- (void)stop;
@end

static dispatch_queue_t queue;
static NSMutableArray<DmRumbleChannel *> *channels[DM_PLAYERS];
static GCController *controllers[DM_PLAYERS];
#if TARGET_OS_IPHONE
static BOOL phoneSupported;
#endif
static float gain = 1;
static pthread_mutex_t routeLock = PTHREAD_MUTEX_INITIALIZER;
static unsigned errors;
static NSTimeInterval now(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
// A plain player cannot loop, and one stopped in the middle of an event leaves an Xbox controller's motors running at its level after the engine and the
// process are gone (gamecontrollerd, macOS 27.0.1; only power-cycling the controller stopped them). So plain players play pulses that end on their own:
// each one PULSE long, the next scheduled where the last ends while the effect lasts; a stop silences them and waits for the last one to end
#define PULSE 0.5
#define PULSE_LEAD 0.15   // the next pulse is made this long before the last one ends
static CHHapticPattern *simple_pattern(dm_haptic_level level, NSError **error) {
    CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[
        [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1],
        [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.5]
    ] relativeTime:0 duration:PULSE];
    // The level is the pattern's own initial control: a plain player has no mute to hide its first instant at full intensity
    return [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:level.intensity relativeTime:0],
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl value:level.sharpness - 0.5f relativeTime:0]
    ] error:error];
}
// Controllers' rumble motors do not turn below a minimum: an Xbox Wireless Controller showed nothing at intensity 0.05, a faint buzz from about 0.1 and
// still a soft one at 0.3, where the Switch's actuators render the low amplitudes many games use (Breath of the Wild's charged attack: 0.07, about 0.25 after
// a gain of 2.5). A nonzero level starts above that minimum and rises as its square root, up to the same full level
#define CONTROLLER_FLOOR 0.15f
static float controller_intensity(float intensity) {
    return intensity > 0 ? fminf(1, CONTROLLER_FLOOR + (1 - CONTROLLER_FLOOR) * sqrtf(intensity)) : 0;
}
static void report(NSError *e, NSString *target, const char *stage) {
    if (++errors <= 8 || errors % 64 == 0) {
        fprintf(stderr, "[RED] haptics: %s %s: %s (%s %ld)\n", target.UTF8String, stage,
                e.localizedDescription.UTF8String ?: "engine unavailable", e.domain.UTF8String ?: "no error", (long)e.code);
        NSError *underlying = e.userInfo[NSUnderlyingErrorKey];
        if (underlying) fprintf(stderr, "[RED] haptics: underlying %s %ld: %s\n", underlying.domain.UTF8String,
                                (long)underlying.code, underlying.userInfo[NSDebugDescriptionErrorKey] ?
                                [underlying.userInfo[NSDebugDescriptionErrorKey] UTF8String] : underlying.localizedDescription.UTF8String);
    }
}

@implementation DmRumbleChannel
- (void)stop {
    self.generation++; self.silenceGeneration++;
    self.engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) { (void)reason; }; self.engine.resetHandler = ^{};
    if (self.simple) {
        // Never cut a pulse: silence the playing ones and stop the engine once the last has ended
        NSArray *zero = @[[[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:0 relativeTime:0]];
        [self.previous sendParameters:zero atTime:CHHapticTimeImmediate error:nil];
        [self.pattern sendParameters:zero atTime:CHHapticTimeImmediate error:nil];
        self.pattern = nil; self.previous = nil; self.level = (dm_haptic_level){0, 0};
        NSTimeInterval left = self.engine ? self.pulseEnd - self.engine.currentTime : 0;
        if (left > 0) {
            __weak DmRumbleChannel *weak = self; CHHapticEngine *engine = self.engine;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((left + 0.05) * NSEC_PER_SEC)), queue, ^{
                DmRumbleChannel *c = weak; if (c && c.engine == engine && c.pattern) return;   // a new effect took the engine meanwhile
                [engine stopWithCompletionHandler:nil];
            });
            return;
        }
    } else {
        [self.pattern stopAtTime:CHHapticTimeImmediate error:nil]; self.pattern = nil;
    }
    [self.engine stopWithCompletionHandler:nil];   // the engine stays: the next effect restarts it
}
// The next pulse at the current level, from where the last one ends, and the renewal of the one after while the effect lasts
- (BOOL)pulse:(NSError **)error {
    id<CHHapticPatternPlayer> next = [self.engine createPlayerWithPattern:simple_pattern(self.level, error) error:error];
    NSTimeInterval at = MAX(self.engine.currentTime, self.pulseEnd);
    if (!next || ![next startAtTime:at error:error]) return NO;
    self.previous = self.pattern; self.pattern = next; self.pulseEnd = at + PULSE;
    __weak DmRumbleChannel *weak = self; uint64_t generation = self.generation;
    NSTimeInterval wait = MAX(0, self.pulseEnd - PULSE_LEAD - self.engine.currentTime);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), queue, ^{
        DmRumbleChannel *c = weak; NSError *e = nil;
        if (!c || c.generation != generation || c.pattern != next || c.level.intensity == 0) return;   // stopped, replaced or silent
        if (![c pulse:&e]) [c failed:e stage:"pulse"];
    });
    return YES;
}
- (void)failed:(NSError *)error stage:(const char *)stage {
    report(error, self.target, stage);
    [self stop]; self.engine = nil;   // A failed helper connection must not be reused for every later vibration.
    self.failures = MIN(self.failures + 1, 4u);
    self.retryAfter = now() + (1u << (self.failures - 1));
    dm_haptics_clear(self.player);
}
- (void)engineFailed:(NSError *)error stage:(const char *)stage {
    [self failed:error stage:stage];
    // Only an engine that cannot be made or started moves a split route to the default locality;
    // a player or parameter failure (a service reset, say) is retried on the same handle.
    if (self.fallback) self.fallback(self.retryAfter);
}
- (BOOL)startEngine {
    NSError *error = nil;
    if (!self.engine) {
        self.engine = self.createEngine(&error);
        if (!self.engine) { [self engineFailed:error stage:"create engine"]; return NO; }
        self.engine.playsHapticsOnly = YES; self.engine.autoShutdownEnabled = NO;
    }
    __weak DmRumbleChannel *weak = self;
    uint64_t generation = ++self.generation;
    void (^reset)(void) = ^{
        dispatch_async(queue, ^{
            DmRumbleChannel *c = weak; if (!c || c.generation != generation) return;
            [c stop];
            dm_haptics_clear(c.player);   // queued effects from before an interruption cannot restart
        });
    };
    self.engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) { (void)reason; reset(); };
    self.engine.resetHandler = reset;
    // Startup can itself fail or reset the service: install handlers before contacting it.
    if (![self.engine startAndReturnError:&error]) { [self engineFailed:error stage:"start engine"]; return NO; }
    return YES;
}
- (void)apply:(dm_haptic_level)level {
    if ([self.target hasPrefix:@"controller"]) level.intensity = controller_intensity(level.intensity);
    uint64_t silence = ++self.silenceGeneration;
    NSError *error = nil;
    self.level = level;
    if (!self.pattern) {
        if (level.intensity == 0) return;
        if (now() < self.retryAfter) {
            // Discard this effect, so an identical fresh send after the backoff is not deduplicated away.
            dm_haptics_clear(self.player); return;
        }
        if (![self startEngine]) return;
        if (!self.simple) {
            CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[
                [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1],
                [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.5]
            ] relativeTime:0 duration:30];
            CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&error];
            id<CHHapticAdvancedPatternPlayer> advanced = pattern ? [self.engine createAdvancedPlayerWithPattern:pattern error:&error] : nil;
            if (advanced) { advanced.loopEnabled = YES; advanced.isMuted = YES; self.pattern = advanced; }
            else if (pattern) {
                // Game controllers' haptic server (gamecontrollerd, macOS 27) reports no advanced players to CoreHaptics ("adv players: 0" in its log), and
                // creating one fails over XPC (NSCocoaErrorDomain 4097): the Xbox controllers never vibrated. The refusal also leaves that engine unusable
                // (a plain player or a restart on it fails with -4810), so plain players play from a new engine
                fprintf(stderr, "haptics: player %d %s has no advanced players (%s %ld): plain players\n", self.player + 1, self.target.UTF8String,
                        error.domain.UTF8String ?: "no error", (long)error.code);
                error = nil;
                [self stop]; self.engine = nil;
                // Without advanced players, the engines of the left and right handles override each other on an Xbox Wireless Controller instead of
                // adding up: with both playing, the handle motors were not felt, while one engine for both handles was
                if (self.merge) { dm_haptics_clear(self.player); self.merge(); return; }
                self.simple = YES;
                if (![self startEngine]) return;
            }
        }
        if (self.simple) {
            self.pulseEnd = 0;
            if (![self pulse:&error]) { [self failed:error stage:"start pulse"]; return; }
        }
        if (!self.pattern) { [self failed:error stage:"create player"]; return; }
        if (!self.simple && ![self.pattern startAtTime:CHHapticTimeImmediate error:&error]) { [self failed:error stage:"start player"]; return; }
    } else if (self.simple && level.intensity > 0 && self.pulseEnd <= self.engine.currentTime) {
        if (![self pulse:&error]) { [self failed:error stage:"start pulse"]; return; }   // the pulses ran out while the effect was silent
    }
    // Controls live outside the loop: the loop boundary never replays an initial intensity.
    NSArray *parameters = @[
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:level.intensity relativeTime:0],
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl value:level.sharpness - 0.5f relativeTime:0]
    ];
    [self.previous sendParameters:parameters atTime:CHHapticTimeImmediate error:nil];   // still playing until the scheduled pulse starts
    if (![self.pattern sendParameters:parameters atTime:CHHapticTimeImmediate error:&error]) {
        [self failed:error stage:"send parameters"]; return;
    }
    self.failures = 0;
    if (!self.simple) ((id<CHHapticAdvancedPatternPlayer>)self.pattern).isMuted = NO;
    if (level.intensity == 0) {
        // Reuse a warm player for nearby pulses, then release idle hardware. This never times out an active effect.
        __weak DmRumbleChannel *weak = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), queue, ^{
            DmRumbleChannel *c = weak; if (c && c.silenceGeneration == silence) [c stop];
        });
    }
}
@end

static void apply(dm_haptic_state s) {
    dispatch_async(queue, ^{ @autoreleasepool {
        if (s.epoch != dm_haptics_epoch(s.player)) return;
        NSArray<DmRumbleChannel *> *out = channels[s.player];
        for (NSUInteger i = 0; i < out.count; i++) {
            if (s.epoch != dm_haptics_epoch(s.player)) break;   // a failed channel may replace this route
            int m = out[i].motor;
            dm_haptic_level level = m >= 0 ? dm_haptics_level(&s.motor[m], 1, gain) : dm_haptics_level(s.motor, 2, gain);
            [out[i] apply:level];
        }
    } });
}
static void add_engine(int p, int motor, NSString *target, CHHapticEngine *(^create)(NSError **)) {
    DmRumbleChannel *c = [DmRumbleChannel new]; c.createEngine = create; c.target = target; c.player = p; c.motor = motor;
    [channels[p] addObject:c];
}
static void default_controller(int p, GCDeviceHaptics *h, NSTimeInterval retryAfter) {
    add_engine(p, -1, @"controller default", ^CHHapticEngine *(NSError **e) { (void)e; return [h createEngineWithLocality:GCHapticsLocalityDefault]; });
    channels[p].lastObject.retryAfter = retryAfter;
}
static void configure(int p, GCController *controller) {
    for (DmRumbleChannel *c in channels[p]) [c stop];
    channels[p] = [NSMutableArray new];
    if (controller) {
        GCDeviceHaptics *h = controller.haptics;
        NSSet *localities = h.supportedLocalities;
        if ([localities containsObject:GCHapticsLocalityLeftHandle] && [localities containsObject:GCHapticsLocalityRightHandle]) {
            add_engine(p, 0, @"controller left handle", ^CHHapticEngine *(NSError **e) { (void)e; return [h createEngineWithLocality:GCHapticsLocalityLeftHandle]; });
            add_engine(p, 1, @"controller right handle", ^CHHapticEngine *(NSError **e) { (void)e; return [h createEngineWithLocality:GCHapticsLocalityRightHandle]; });
            // Advertised handle localities can still fail to start. Fall back to the standard
            // controller engine, once, rather than keeping two unusable helper connections.
            __weak NSArray *route = channels[p];
            for (DmRumbleChannel *c in channels[p]) c.fallback = ^(NSTimeInterval retryAfter) {
                if (!route || channels[p] != route) return;
                for (DmRumbleChannel *old in channels[p]) [old stop];
                channels[p] = [NSMutableArray new];
                default_controller(p, h, retryAfter);
                dm_haptics_route(p, 1);
                fprintf(stderr, "haptics: player %d retrying with the default controller locality\n", p + 1);
            };
            // A server without advanced players gets one engine for both handles (see apply)
            for (DmRumbleChannel *c in channels[p]) c.merge = ^{
                if (!route || channels[p] != route) return;
                for (DmRumbleChannel *old in channels[p]) [old stop];
                channels[p] = [NSMutableArray new];
                GCHapticsLocality both = [localities containsObject:GCHapticsLocalityHandles] ? GCHapticsLocalityHandles : GCHapticsLocalityDefault;
                add_engine(p, -1, @"controller handles", ^CHHapticEngine *(NSError **e) { (void)e; return [h createEngineWithLocality:both]; });
                channels[p].lastObject.simple = YES;
                dm_haptics_route(p, 1);
                fprintf(stderr, "haptics: player %d plays both motors on one engine (%s)\n", p + 1, both.UTF8String);
            };
        }
        else if (localities.count) default_controller(p, h, 0);
        fprintf(stderr, "haptics: player %d controller %s, localities %s, %lu channels\n", p + 1,
                controller.vendorName.UTF8String ?: "unknown", [[localities.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "].UTF8String ?: "none", (unsigned long)channels[p].count);
    }
#if TARGET_OS_IPHONE
    else if (!p && phoneSupported) {
        // Do not initialize the phone's engine before the game's audio session is active.
        add_engine(p, -1, @"phone", ^CHHapticEngine *(NSError **e) { return [[CHHapticEngine alloc] initWithAudioSession:AVAudioSession.sharedInstance error:e]; });
    }
#endif
    dm_haptics_route(p, channels[p].count != 0);
}
void dm_haptics_apple_controller(int p, GCController *controller) {
    if (!queue || p < 0 || p >= DM_PLAYERS) return;
    pthread_mutex_lock(&routeLock);
    if (controllers[p] != controller) {
        controllers[p] = controller;
        dm_haptics_route(p, 0);   // invalidate queued work before changing hardware
        dispatch_sync(queue, ^{ configure(p, controller); });
    }
    pthread_mutex_unlock(&routeLock);
}
static void suspend(unsigned reason, BOOL on) {
    dm_haptics_suspend(reason, on);
    void (^stop)(void) = ^{
        for (int p = 0; p < DM_PLAYERS; p++) for (DmRumbleChannel *c in channels[p]) [c stop];
    };
    if (on) { if (dispatch_get_specific(&queue)) stop(); else dispatch_sync(queue, stop); }
}
void dm_haptics_apple_shutdown(void) {
    if (queue) suspend(DM_HAPTICS_INACTIVE, YES);
}
void dm_haptics_apple_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("dm.rumble", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(queue, &queue, &queue, NULL);
        const char *e = getenv("DM_RUMBLE_GAIN");
        if (e) { float v = strtof(e, NULL); if (isfinite(v)) gain = fmaxf(0, fminf(3, v)); }
        e = getenv("DM_RUMBLE");
        dm_haptics_init(apply, !e || atoi(e) != 0);
#if TARGET_OS_IPHONE
        phoneSupported = CHHapticEngine.capabilitiesForHardware.supportsHaptics;
#endif
        dispatch_sync(queue, ^{ configure(0, nil); });
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
#if TARGET_OS_IPHONE
        [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) { (void)n; suspend(DM_HAPTICS_INACTIVE, YES); }];
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) { (void)n; suspend(DM_HAPTICS_INACTIVE, NO); }];
        [nc addObserverForName:UIApplicationWillTerminateNotification object:nil queue:nil usingBlock:^(NSNotification *n) { (void)n; dm_haptics_apple_shutdown(); }];
        [nc addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            suspend(DM_HAPTICS_INTERRUPTED, [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan);
        }];
        [nc addObserverForName:AVAudioSessionRouteChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            (void)n; dm_haptics_clear(0);
        }];
#else
        [nc addObserverForName:NSApplicationWillResignActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) { (void)n; suspend(DM_HAPTICS_INACTIVE, YES); }];
        [nc addObserverForName:NSApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) { (void)n; suspend(DM_HAPTICS_INACTIVE, NO); }];
        [nc addObserverForName:NSApplicationWillTerminateNotification object:nil queue:nil usingBlock:^(NSNotification *n) { (void)n; dm_haptics_apple_shutdown(); }];
#endif
        atexit(dm_haptics_apple_shutdown);
    });
}
