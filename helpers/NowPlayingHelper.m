// Streams the system's Now Playing state (the one Control Center shows) as JSON lines.
//
// macOS lets only Apple's own programs read it (MediaRemote), so Hanabi runs this inside
// Apple's /usr/bin/perl, which is allowed:
//   /usr/bin/perl -e '<DynaLoader glue>' /path/NowPlayingHelper.dylib
// One line per change (play, pause, seek, skip, new song) plus a heartbeat every 5 s:
//   {"pid":123,"title":"…","artist":"…","album":"…","duration":166.4,"elapsed":42.1,"rate":1,"timestamp":1790457715.5}
// `elapsed` was true at `timestamp` (Unix time) and moves at `rate`. It exits when Hanabi
// goes away (its stdin closes).
#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*RegisterFn)(dispatch_queue_t);
typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*GetPIDFn)(dispatch_queue_t, void (^)(int));

static GetInfoFn getInfo;
static GetPIDFn getPID;

static id value(NSDictionary *info, NSString *key) { return info[[@"kMRMediaRemoteNowPlayingInfo" stringByAppendingString:key]]; }

static void emit(void) {
    dispatch_queue_t q = dispatch_get_main_queue();
    getInfo(q, ^(NSDictionary *info) {
        getPID(q, ^(int pid) {
            NSMutableDictionary *out = [NSMutableDictionary dictionaryWithObject:@(pid) forKey:@"pid"];
            if (info) {
                NSDictionary *keys = @{@"title": @"Title", @"artist": @"Artist", @"album": @"Album",
                                       @"duration": @"Duration", @"elapsed": @"ElapsedTime", @"rate": @"PlaybackRate"};
                for (NSString *k in keys) { id v = value(info, keys[k]); if (v) out[k] = v; }
                NSDate *stamp = value(info, @"Timestamp");
                if ([stamp isKindOfClass:[NSDate class]]) out[@"timestamp"] = @(stamp.timeIntervalSince1970);
            }
            NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
            if (json) { fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout); fflush(stdout); }
        });
    });
}

// Called from perl as an XS sub (perl passes its interpreter and CV; unused).
void hanabi_now_playing(void *interpreter, void *cv) {
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!mr) { fprintf(stderr, "no MediaRemote\n"); exit(1); }
    RegisterFn registerFn = (RegisterFn)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    getInfo = (GetInfoFn)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    getPID = (GetPIDFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationPID");
    if (!registerFn || !getInfo || !getPID) { fprintf(stderr, "MediaRemote symbols missing\n"); exit(1); }

    registerFn(dispatch_get_main_queue());
    const char *names[] = {"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                           "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                           "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"};
    for (int i = 0; i < 3; i++) {
        NSString *__strong *symbol = (NSString *__strong *)dlsym(mr, names[i]);
        NSString *name = symbol ? *symbol : @(names[i]);
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) { emit(); }];
    }
    emit();

    // Heartbeat, so a missed notification never leaves Hanabi stale for long.
    dispatch_source_t beat = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(beat, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(beat, ^{ emit(); });
    dispatch_resume(beat);

    // Hanabi quit (or crashed): our stdin closes, so we go too.
    dispatch_source_t input = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(input, ^{
        char buffer[256];
        if (read(STDIN_FILENO, buffer, sizeof buffer) <= 0) exit(0);
    });
    dispatch_resume(input);

    CFRunLoopRun();
}
