# 5 · Knowing what's playing

Himawari's music wallpaper depends on one question being answered quickly and correctly: what
is the Music app playing right now, where is it in the song, and what does the album look like?
Once the answer is known, the app can swap the desktop for the album's animated "motion
artwork", for a muted YouTube video of the song, or for a spinning-CD scene showing the cover.
This chapter covers the code that answers that question and fetches the media. It does not
cover the code that draws the media; that is the wallpaper chapter.

Three files make up the pipeline:

| File | Lines | Language | Role |
|---|---|---|---|
| `Sources/HimawariKit/NowPlaying.swift` | 709 | Swift | `MusicNowPlaying` (the model the app observes), `MotionArtwork` (finds Apple Music motion artwork), `YouTubeLoop` (finds a YouTube fallback), `YouTubeLoopView` (plays it) |
| `Sources/HimawariKit/SystemNowPlaying.swift` | 113 | Swift | Starts the MediaRemote helper inside `/usr/bin/perl` and parses its JSON-lines output |
| `helpers/NowPlayingHelper.m` | 90 | Objective-C | A dynamic library that calls the private MediaRemote framework and prints one JSON line per change |

The pipeline has four separate sources of information. Each covers a gap left by the others:

```
                 ┌────────────────────────────────────────────────────────────┐
                 │                    MusicNowPlaying (@MainActor)            │
                 │  track · isPlaying · position · artwork · motionVideo ·    │
                 │  youtubeVideos · searching                                 │
                 └───▲──────────────▲──────────────────▲──────────────▲───────┘
                     │              │                  │              │
   (1) Distributed   │  (2) System  │   (3) AppleScript│   (4) The web│
   notification      │  Now Playing │   to Music       │              │
   com.apple.Music.  │  via perl +  │   NSAppleScript  │  iTunes Search API,
   playerInfo        │  MediaRemote │   + osascript    │  music.apple.com pages,
   (track, state)    │  (track,     │   (track, pos,   │  mzstatic / mvod CDNs,
   no permission     │  exact pos,  │   cover, all     │  youtube.com results
                     │  exact cover)│   controls)      │  (motion video, cover,
                     │              │   TCC prompt     │   YouTube ids)
```

1. **Music's distributed notification** says the song changed or the player state changed. It
   needs no permission, but it has no playback position and no artwork.
2. **The system Now Playing stream** (MediaRemote, the data behind Control Center's media
   widget) gives the exact elapsed time with a timestamp and playback rate, plus the exact cover
   image Music is showing. On current macOS it is only readable by Apple-signed programs, which is
   why the helper runs inside `/usr/bin/perl`.
3. **AppleScript** works on every macOS version and is the only one of the four that can *change*
   anything (play, pause, seek, volume, repeat, shuffle, equalizer). It costs an Automation (TCC)
   permission prompt the first time.
4. **The public web** (Apple's iTunes Search API, Apple Music's public album pages, YouTube's
   search page) supplies what Music does not expose at all: motion artwork, and a YouTube video
   when there is no motion artwork.

The rest of the chapter goes file by file, in the order the data flows: the helper, its Swift
launcher, then the model and the search code.

---

## helpers/NowPlayingHelper.m

### Purpose and place in the app

This 90-line Objective-C file builds into `NowPlayingHelper.dylib`, which goes in
`Himawari.app/Contents/Resources/`. It is not linked into Himawari. Instead
`SystemNowPlaying` loads it into a separate `/usr/bin/perl` process. Once loaded, it subscribes to
the system's Now Playing notifications and writes one JSON object per line to standard output
each time something changes. It also writes one every five seconds as a heartbeat. It exits when
its standard input closes, which happens when Himawari quits or crashes.

`build.sh:67-70` builds and signs it:

```
clang -dynamiclib -fobjc-arc -O2 -mmacosx-version-min=14.4 ${ARCHS[@]+"${ARCHS[@]}"} -framework Foundation \
    helpers/NowPlayingHelper.m -o build/Himawari.app/Contents/Resources/NowPlayingHelper.dylib
codesign --force --sign "$IDENTITY" build/Himawari.app/Contents/Resources/NowPlayingHelper.dylib
```

It links only Foundation. MediaRemote is opened at run time with `dlopen`, because MediaRemote is
a private framework with no headers and no stub library to link against. The deployment target
of 14.4 matches `Package.swift`'s `platforms: [.macOS("14.4")]` and `LSMinimumSystemVersion` in
`Resources/Info.plist`.

### Background: MediaRemote and the macOS 15.4 restriction

MediaRemote (`/System/Library/PrivateFrameworks/MediaRemote.framework`) is the private framework
behind Control Center's "Now Playing" module, the media keys and the lock-screen controls. A
system daemon, `mediaremoted`, keeps the current "now playing" state for whichever app is playing
and sends it to clients. Its C functions include `MRMediaRemoteGetNowPlayingInfo` (an
asynchronous call that returns an `NSDictionary` whose keys start with
`kMRMediaRemoteNowPlayingInfo…`), `MRMediaRemoteGetNowPlayingApplicationPID`, and
`MRMediaRemoteRegisterForNowPlayingNotifications`, which tells the framework to post
`NSNotification`s when the state changes.

For years any process could `dlopen` the framework and call these functions, and many menu-bar
"now playing" apps did. The source comments (`SystemNowPlaying.swift:4-5`,
`NowPlayingHelper.m:3-4`) describe what changed: "macOS lets only Apple's own programs read it".
Starting with macOS 15.4, `mediaremoted` stopped returning now-playing information to ordinary
third-party processes. Programs that Apple signed as part of the OS still get it. The
community-known workaround, which this file uses, is to run your code *inside* such a program.
`/usr/bin/perl` is a good host for three reasons:

* It ships with every macOS installation. `/usr/bin/python3`, by contrast, is a stub that offers
  to install the Command Line Tools.
* It is an Apple platform binary, so `mediaremoted` treats it as Apple's own.
* Its standard `DynaLoader` module can load any shared library and call a C function in it as a
  Perl subroutine. This works only because perl's code signature lets it load a library that
  Apple did not sign. The design depends on that.

So the trick is Perl in name only. The single line of Perl in `SystemNowPlaying.glue` loads the
dylib and calls `himawari_now_playing`, which never returns.

### Static state

| Name | Type | Meaning |
|---|---|---|
| `getInfo` | `GetInfoFn` (`void (*)(dispatch_queue_t, void (^)(NSDictionary *))`) | Pointer to `MRMediaRemoteGetNowPlayingInfo`, resolved by `dlsym` |
| `getPID` | `GetPIDFn` (`void (*)(dispatch_queue_t, void (^)(int))`) | Pointer to `MRMediaRemoteGetNowPlayingApplicationPID` |
| `lastArtwork` | `NSString *` | Key of the cover most recently sent, so the base64 image goes out only once per cover |

`RegisterFn` (`void (*)(dispatch_queue_t)`) is the third typedef. It is only used locally. The
three function-pointer signatures are not in any public header. They are the reverse-engineered
signatures that the open-source community has used for MediaRemote for years.

### `value(info, key)`

```objc
static id value(NSDictionary *info, NSString *key) { return info[[@"kMRMediaRemoteNowPlayingInfo" stringByAppendingString:key]]; }
```
(`NowPlayingHelper.m:22`)

A shorthand for looking up a key. MediaRemote's info dictionary uses keys like
`kMRMediaRemoteNowPlayingInfoTitle` and `kMRMediaRemoteNowPlayingInfoElapsedTime`. The helper
builds those strings itself rather than reading the exported `NSString *` constants. This works
because each constant's value is the same text as its symbol name.

### `emit()`

`emit` (`NowPlayingHelper.m:24-52`) asks MediaRemote for the current state and prints it. It
makes two nested asynchronous calls, both answering on the main queue:

1. `getInfo(q, ^(NSDictionary *info) { … })` gets the info dictionary. `info` can be `nil` when
   nothing is playing.
2. Inside that block, `getPID(q, ^(int pid) { … })` gets the process ID of the app that owns the
   Now Playing session. Himawari uses it to ignore everything except Music.
3. It builds `out`, an `NSMutableDictionary` that starts as `{"pid": pid}`. If `info` is not nil,
   it copies six fields through a mapping table:

   | JSON key | MediaRemote suffix | Type / unit |
   |---|---|---|
   | `title` | `Title` | string |
   | `artist` | `Artist` | string |
   | `album` | `Album` | string |
   | `duration` | `Duration` | number, seconds |
   | `elapsed` | `ElapsedTime` | number, seconds, true at `timestamp` |
   | `rate` | `PlaybackRate` | number, 1 = playing, 0 = paused |

   A key is written only if MediaRemote has a value for it, so missing fields are left out of
   the JSON rather than sent as `null`.
4. `Timestamp` is an `NSDate`. It is converted to Unix seconds (`timeIntervalSince1970`) so it
   can go into JSON. MediaRemote does not update `ElapsedTime` continuously. It reports
   "*elapsed* was the position at *timestamp*, moving at *rate*", and the reader works out the
   present position. That is why the format carries all three.
5. Artwork. `ArtworkIdentifier` is a string. For streamed Apple Music songs it is the image's URL
   on Apple's `mzstatic.com` image server. If present it goes out on every line as `artworkID`.
   `ArtworkData` is the image bytes (usually JPEG). It can be hundreds of kilobytes, so it is
   sent only when the cover changes. The dedupe key is the identifier, or, when there is no
   identifier, `"<length>-<hash>"` of the data. If the key differs from `lastArtwork`, the data
   is base64-encoded into `artwork` and `lastArtwork` is updated.
6. `NSJSONSerialization` turns `out` into compact JSON, which is written to `stdout` with
   `fwrite`, followed by `'\n'` and `fflush(stdout)`. The flush matters: stdout is a pipe, which
   the C library buffers fully, so without the flush lines would arrive in bursts minutes late.

The output format, as documented at the top of the file (`NowPlayingHelper.m:7-8`):

```
{"pid":123,"title":"…","artist":"…","album":"…","duration":166.4,"elapsed":42.1,"rate":1,"timestamp":1790457715.5,
 "artworkID":"https://…/800x800bb.jpg", "artwork":"<base64 JPEG, only when the cover changes>"}
```

### `himawari_now_playing(interpreter, cv)`

This is the entry point. Its signature is that of a Perl XS subroutine: Perl calls an installed
XSUB as `void f(PerlInterpreter *, CV *)`. Both arguments are ignored (`NowPlayingHelper.m:54`).
The function's steps:

1. `dlopen` MediaRemote with `RTLD_NOW`. On failure it prints `no MediaRemote` to stderr and
   calls `exit(1)`. Himawari sends stderr to `/dev/null`, so the only visible effect is that the
   process ends, which makes `SystemNowPlaying` retry.
2. Resolve the three functions with `dlsym`. If any is missing, `exit(1)`.
3. `registerFn(dispatch_get_main_queue())`. This turns on notification posting.
4. Subscribe to three notifications on `NSNotificationCenter.defaultCenter`, each calling
   `emit()`:
   `kMRMediaRemoteNowPlayingInfoDidChangeNotification` (metadata, elapsed time, artwork),
   `kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification` (play/pause), and
   `kMRMediaRemoteNowPlayingApplicationDidChangeNotification` (a different app took over).
   For each one it tries to read the exported `NSString *` constant with `dlsym`. If that fails
   it uses the C string itself as the name (`NowPlayingHelper.m:68-69`). Like `value()`, the
   fallback assumes name and value are equal.
5. Call `emit()` once so Himawari gets the current state immediately.
6. Start a heartbeat: a `DISPATCH_SOURCE_TYPE_TIMER` on the main queue that fires every 5 s, with
   0.5 s leeway, and calls `emit()`. On the Swift side, `MusicNowPlaying.systemLive` treats the
   stream as live if a message arrived in the last 12 s, which allows for two missed beats.
7. Watch for the parent going away: a `DISPATCH_SOURCE_TYPE_READ` source on `STDIN_FILENO`. When
   stdin becomes readable it reads up to 256 bytes. A return of `0` (EOF) or a negative value
   (error) calls `exit(0)`. Himawari never writes to the pipe, so the only event this source
   ever sees is EOF, which comes when the kernel closes the write end because Himawari exited.
   This avoids orphaned perl processes without any signal handling.
8. `CFRunLoopRun()` never returns. The run loop services the main dispatch queue, so all the
   asynchronous MediaRemote callbacks, notifications and dispatch sources above run on this one
   thread. That is also why there is no locking around `lastArtwork`.

### Design decisions

* **A push stream, not polling.** Notifications plus a slow heartbeat cost nearly nothing when
  nothing changes, and deliver play/pause/seek within one MediaRemote callback.
* **JSON lines.** Easy to write from Foundation, easy to parse in Swift
  (`JSONSerialization`), and robust to splitting across pipe reads because each record ends with
  a newline.
* **Cover only once.** Sending a base64 JPEG every five seconds would mean several megabytes per
  minute through the pipe and the parser.
* **Lifetime tied to stdin.** This is simpler than having perl watch the parent PID, and it
  works when Himawari crashes.

### Notes and risks

* `NowPlayingHelper.m:26-27`: info and PID come from two separate asynchronous calls. If the
  Now Playing app changes between them, a line can pair one app's metadata with another app's
  PID. The heartbeat corrects it within 5 s.
* `NowPlayingHelper.m:48`: `+dataWithJSONObject:` raises an Objective-C exception rather than
  returning nil for values JSON cannot represent (for example a NaN `Duration` or
  `ElapsedTime`). That would end the helper. `SystemNowPlaying` restarts it at most five times.
* `NowPlayingHelper.m:42-45`: `lastArtwork` is set when the data is *sent*, not when Himawari
  *accepts* it. If the Swift side rejects a cover (see the stale-cover guard below), the helper
  will not send that identifier's image again until the identifier changes.
* `NowPlayingHelper.m:41`: the fallback key `length-hash` uses `-[NSData hash]`, which on Apple
  platforms hashes only a prefix of the bytes. Two different covers of the same length and the
  same opening bytes would count as one.
* The whole file depends on private signatures and on perl being allowed to load an unsigned
  library and read MediaRemote. Apple can close either route in a future release. The Swift side
  is written so that the app then simply falls back to AppleScript.

---

## Sources/HimawariKit/SystemNowPlaying.swift

### Purpose and place in the app

This 113-line file holds one class, `SystemNowPlaying`. It runs the helper and turns its output
into `State` values on the main actor. Its only client is `MusicNowPlaying.init`
(`NowPlaying.swift:86-89`), which creates it only if `NowPlayingHelper.dylib` is in the main
bundle's resources. In a `swift run` debug build without `build.sh`, the dylib is missing, so no
`SystemNowPlaying` exists and the model relies on AppleScript alone. The file comment states the
design rule: "If it can't run (a future macOS closes the door), this simply reports nothing and
callers keep asking Music over AppleScript."

### `SystemNowPlaying.State`

A `Sendable` value struct that mirrors one JSON line.

| Property | Type | Meaning |
|---|---|---|
| `pid` | `Int32` | PID of the app owning Now Playing (0 if absent) |
| `title`, `artist`, `album` | `String?` | Metadata; `nil` when the line had none |
| `duration` | `Double` | Song length in seconds (0 if absent) |
| `elapsed` | `Double` | Seconds into the song, true at `timestamp` |
| `rate` | `Double` | Playback rate; 0 = paused |
| `timestamp` | `Double` | Unix time of the `elapsed` reading; defaults to "now" when absent |
| `artworkID` | `String?` | Cover identifier (an `mzstatic.com` URL for streamed songs) |
| `artwork` | `Data?` | Decoded cover image bytes; only in the first line after a cover change |

### `SystemNowPlaying` — stored state

| Property | Type | Meaning |
|---|---|---|
| `glue` (static) | `String` | The one-line Perl program passed with `-e` |
| `helper` | `URL` | Path to `NowPlayingHelper.dylib` |
| `onState` | `@MainActor (State) -> Void` | Callback to the owner (`MusicNowPlaying.apply`) |
| `process` | `Process?` | The running perl process, or nil |
| `input` | `Pipe?` | The perl process's stdin pipe. Kept so the write end stays open; closing it tells the helper to exit |
| `pending` | `Data` | Bytes received but not yet ending in a newline. Touched only on `queue` |
| `queue` | `DispatchQueue` (serial, `local.dhairyabhatia.nowplaying.system`) | Where parsing happens |
| `failures` | `Int` | Consecutive failures, for the retry backoff |
| `stopped` | `Bool` | Set by `stop()` so a termination doesn't trigger a restart |

**Threading.** The class is `@unchecked Sendable`, so the compiler does not check its isolation.
The rule the code follows is: `pending` is touched only on `queue`; `process`, `input`,
`failures` and `stopped` are touched on the main thread (`start` is called from the
main-actor `MusicNowPlaying.init`, `helperEnded` is dispatched to main, and the `failures = 0`
reset in `consume` is dispatched to main). The callback runs on main through `onMainActor`, the
project's helper that asserts `Thread.isMainThread` and then calls the closure as main-actor code
without querying the Swift runtime's executor (see `Sources/HimawariKit/MainThread.swift`).

**Lifecycle.** `MusicNowPlaying` keeps it in a private property for its whole life, which is the
app's life, since `AppDelegate` owns a single `MusicNowPlaying` (`AppDelegate.swift:16`). Nothing
calls `stop()` in the current app. The helper exits through the stdin EOF path when Himawari
exits.

### The Perl glue

```swift
private static let glue = """
require DynaLoader; my $l = DynaLoader::dl_load_file($ARGV[0]) or die DynaLoader::dl_error(); \
my $s = DynaLoader::dl_find_symbol($l, "himawari_now_playing") or die "no symbol"; \
DynaLoader::dl_install_xsub("main::run", $s); run();
"""
```
(`SystemNowPlaying.swift:21-25`)

The trailing backslashes inside the Swift multi-line literal join the lines, so perl gets a
single line. `dl_load_file` is DynaLoader's wrapper around `dlopen`. `dl_find_symbol` is its
wrapper around `dlsym`. `dl_install_xsub` registers the C function pointer as a Perl subroutine
named `main::run`, and `run()` calls it. From then on the process is the helper's run loop. The
dylib path is passed as `$ARGV[0]`, not interpolated into the program text, so a path containing
quotes or spaces cannot break the Perl.

### `init(helper:onState:)`

This only stores the two arguments. Nothing runs until `start()`.

### `start()`

`SystemNowPlaying.swift:41-68`. Steps:

1. `stopped = false`.
2. `removexattr(helper.path, "com.apple.quarantine", 0)`. When an app is downloaded (for example
   from the DMG `scripts/make_dmg.sh` builds), Gatekeeper's quarantine attribute can end up on
   files inside the bundle, and perl refuses to load a quarantined library. Himawari has
   already been approved by the time it runs, so removing the attribute from its own resource
   is safe. The return value is ignored, so a read-only location (running from a mounted DMG)
   fails silently.
3. Configure a `Process` running `/usr/bin/perl -e <glue> <helper path>`.
4. Two `Pipe`s. stdout goes to `output`. stdin comes from `input`, which `start` keeps open so
   the helper does not exit (see the helper's stdin watcher). stderr goes to
   `FileHandle.nullDevice`.
5. `readabilityHandler` on the read end of the output pipe. Foundation calls it on a background
   queue whenever data arrives. An empty `availableData` means EOF, and the handler then removes
   itself. The comment explains why: an EOF file handle stays "readable" forever, so the handler
   would otherwise spin at 100 % CPU. Non-empty data goes to `queue` for `consume`.
6. `terminationHandler` dispatches `helperEnded()` to the main queue.
7. `try p.run()`. On success it stores `process` and `input`. On failure it increments `failures`
   and does nothing else (see Notes).

Both closures capture `self` weakly, so the `Process` (which keeps its handlers) does not keep
`SystemNowPlaying` alive.

### `helperEnded()`

`SystemNowPlaying.swift:71-81`. Restart with linear backoff:

```
helper exits ──► process = nil, input = nil
                 stopped?           → done
                 failures += 1
                 failures > 5?      → give up (AppleScript remains)
                 after failures × 2 s → start() again (if still not stopped and nothing running)
```

So the delays are 2, 4, 6, 8 and 10 s, and after the fifth consecutive failure the stream stays
off for the rest of the session. "Consecutive" because `consume` resets `failures` to 0 on every
line it parses: a helper that has worked and then dies gets the full five retries again.
Re-checking `process == nil` in the delayed block guards against a second, overlapping restart.

### `stop()`

Sets `stopped`, sends SIGTERM through `process?.terminate()`, and drops both references. Because
`stopped` is set first, the termination handler's `helperEnded` returns early and does not
restart.

### `consume(_:)`

`SystemNowPlaying.swift:90-112`, always on `queue`. It splits a byte stream into lines:

1. Append the chunk to `pending`.
2. While `pending` contains `0x0A` (newline): take the bytes before it as one line, remove them
   and the newline from `pending`, and parse the line with `JSONSerialization`. If the line does
   not parse as a dictionary it is skipped with `continue`. One bad line never stops the stream.
3. Build a `State`. Numbers come through `NSNumber` so that integer and floating JSON both work:
   `"rate":1` arrives as an integer `NSNumber`, and `as? Double` would fail on some of these.
   Missing numbers become 0, except `timestamp`, which defaults to the current Unix time.
   `artwork` is base64-decoded. Invalid base64 becomes `nil`.
4. Dispatch to main: reset `failures` to 0, then call `onState` through `onMainActor`.
   `onState` is copied to a local (`deliver`) first, so the closure captures the function
   itself rather than `self`.

A partial line simply stays in `pending` until the rest arrives. This matters for the large
artwork lines, which can take several pipe reads.

### Design decisions

* **Process plus pipes instead of XPC or a launch agent.** The only thing that can read
  MediaRemote is an Apple binary, and the only such binary that can be told to run our code is a
  script interpreter. A plain child process is the simplest way to host it, and its lifetime
  follows the app's.
* **Parsing off the main thread.** Base64-decoding and JSON-parsing a cover can take a few
  milliseconds. Doing it on `queue` keeps the main thread free.
* **Fail open.** Every error path (no dylib, perl refuses, MediaRemote refuses, five crashes)
  ends with the stream silent, and `MusicNowPlaying` falls back to AppleScript after 12 s.

### Notes and risks

* `SystemNowPlaying.swift:65-67`: when `p.run()` throws, `failures` goes up but no retry is
  scheduled, because `terminationHandler` only fires for a process that started. A launch failure
  is permanent for the session.
* `SystemNowPlaying.swift:8`: `@unchecked Sendable` relies on the main-thread rule above.
  `start()` is public and nothing enforces calling it on main.
* `SystemNowPlaying.swift:44`: `removexattr` changes a file inside the signed app bundle. Extended
  attributes are not part of the code signature, so this is harmless today, but it is a write
  into the app's own bundle.
* `SystemNowPlaying.swift:31`: `pending` has no size limit. A helper that wrote without newlines
  would grow it without bound. The helper always writes newlines, so this is theoretical.
* `SystemNowPlaying.swift:83`: `stop()` is never called, so there is no deterministic shutdown.
  It relies on stdin EOF.

---

## Sources/HimawariKit/NowPlaying.swift

### Purpose and place in the app

This is the largest file in the pipeline (709 lines). It defines four public types:

| Type | Lines | Kind | Responsibility |
|---|---|---|---|
| `MusicNowPlaying` | 18-417 | `@MainActor final class`, `ObservableObject` | Merges the four sources into published state; runs AppleScript; controls |
| `MotionArtwork` | 419-558 | caseless `enum` (namespace) | Finds an album's Apple Music motion artwork and cover; chooses an HLS variant |
| `YouTubeLoop` | 560-630 | caseless `enum` | Finds candidate YouTube videos for a song; text normalisation shared with `MotionArtwork` |
| `YouTubeLoopView` | 632-708 | `NSView` subclass | Plays those videos muted and on repeat through YouTube's iframe player in a `WKWebView` |

It imports `QuartzCore` (for `CACurrentMediaTime`), `AppKit` (`NSImage`, `NSRunningApplication`,
`NSWorkspace`, `DistributedNotificationCenter`), `AVFoundation` and `SwiftUI` (for
`ObservableObject`/`@Published`, which come through Combine), and `WebKit`.

Who uses it: `Sources/Himawari/AppDelegate.swift` owns the single `MusicNowPlaying`, subscribes to
its `$motionVideo`, `$isPlaying`, `$youtubeVideos`, `$artwork`, `$searching`, `$track` and
`$position` publishers, and maps the side-gear controls to its methods.
`Sources/Himawari/WallpaperManager.swift` calls `MotionArtwork.bestVariant` before playing a
motion video and creates `YouTubeLoopView`s.

The doc comment at the top (`NowPlaying.swift:7-17`) explains the main design decision: motion
artwork is not available from any free official API. Apple's official Apple Music API needs a
paid developer account and a signed developer token. So Himawari uses the public iTunes Search
API to find the album, then reads the album's public `music.apple.com` web page to find the video
URL. If Apple changes that page, the feature "quietly falls back to the still cover".

---

### `MusicNowPlaying.Track`

```swift
public struct Track: Equatable {
    public let name: String
    public let artist: String
    public let album: String
    public let duration: Double // seconds

    // Same song whichever source reports it (they round the duration differently).
    public static func == (a: Track, b: Track) -> Bool { a.name == b.name && a.artist == b.artist && a.album == b.album }
}
```
(`NowPlaying.swift:20-28`)

The custom `==` deliberately ignores `duration`. The three sources report it in different ways:
the distributed notification gives `Total Time` in integer milliseconds, AppleScript gives a
floating-point number of seconds, and MediaRemote gives its own rounding. If duration counted,
every switch between sources would look like a song change and reset the position, the
artwork and the search. A side effect is that the first source to report a song decides the
duration until the song changes, since `set(track:playing:)` ignores an "equal" track.

### `MusicNowPlaying` — stored state

Published (observed by `AppDelegate` through Combine):

| Property | Type | Meaning |
|---|---|---|
| `track` | `Track?` | Current song, nil when nothing is playing or Music isn't running |
| `isPlaying` | `Bool` | Music is playing (not paused or stopped) |
| `position` | `Double` | Seconds into the song, updated about once a second while `tracksPosition` |
| `artwork` | `NSImage?` | Cover of the current song, or nil while it is being found |
| `motionVideo` | `URL?` | HLS master playlist (`.m3u8`) of the album's motion artwork |
| `youtubeVideos` | `[String]` | Up to four YouTube video IDs to try, in order |
| `searching` | `Bool` | Still looking for this song's motion artwork or YouTube video |

Public, not published:

| Property | Type | Meaning |
|---|---|---|
| `measuredPosition` | `Double` | Last actual position reading, in seconds |
| `measuredAt` | `Double` | When that reading was true, in `CACurrentMediaTime()` seconds |
| `youtubeFallback` | `Bool` (default `true`) | Search YouTube when there is no motion artwork |
| `tracksPosition` | `Bool` (default `true`) | Run the one-second timer; its `didSet` starts or stops ticking |

Private:

| Property | Type | Meaning |
|---|---|---|
| `timer` | `Timer?` | The one-second tick |
| `system` | `SystemNowPlaying?` | The MediaRemote stream, if the helper exists |
| `systemAt` | `Double` | `CACurrentMediaTime()` of the last Music message from the stream (initially −∞) |
| `systemArtworkGeneration` | `Int` | The `generation` whose cover came from the system (initially −1) |
| `systemLive` (computed) | `Bool` | `systemAt` is less than 12 s ago |
| `ticks` | `Int` | Count of ticks, for "refresh every fifth" |
| `generation` | `Int` | Increments on every song change; guards all asynchronous work |
| `shownArtwork` | `(id: String?, album: String)?` | The system cover last applied and the album it was for |
| `artworkFile` | `URL` | `$TMPDIR/now-playing-<pid>.img`, where AppleScript writes the cover |
| `motionCache` (static) | `[String: MotionArtwork.Result]` | Motion-artwork results keyed `artist|album` |
| `youtubeCache` (static) | `[String: [String]]` | YouTube IDs keyed `artist|song name` |
| `music` (static) | `String` | `"com.apple.Music"`, the Music app's bundle identifier |
| `scriptQueue` (static) | `DispatchQueue` | Serial queue for in-process AppleScript |
| `compiled` (static) | `[String: NSAppleScript]` | Compiled scripts keyed by their source, `nonisolated(unsafe)`, touched only on `scriptQueue` |

**Units and clocks.** All positions and durations are in seconds. Two clocks are in play:
`CACurrentMediaTime()` (monotonic seconds since boot, not affected by wall-clock changes) is used
for `measuredAt`, `systemAt` and tick arithmetic. Unix time (`Date().timeIntervalSince1970`) is
used only to work out how old a MediaRemote reading is, because the helper's timestamp is a Unix
time.

**Threading.** The class is `@MainActor`, so all instance state is main-actor-isolated, and the
static caches are too. Background work goes through three channels: `osascript` (a global
utility queue running a child process), `timedScript` (the serial `scriptQueue` running
`NSAppleScript`), and `Task { … }` blocks created from main-actor methods. Those Tasks inherit the
main actor, and their `await URLSession…` calls suspend without blocking it. Every result is
checked against `generation` before it changes state.

**Lifecycle.** `AppDelegate` creates one instance as a stored property (`AppDelegate.swift:16`),
and it lives as long as the app. There is no `deinit`. The timer and the notification block
capture `self` weakly, so a discarded instance would not be kept alive, but the
distributed-notification observer token is never removed (see Notes).

### The generation counter

Almost every asynchronous result in this class can come back after the song has changed: an
AppleScript cover read, an iTunes search, an Apple Music page fetch, a YouTube search, a 1200-px
cover download. The class handles this one way everywhere. `set(track:playing:)` increments
`generation` on each real song change. Each piece of async work captures the generation it
started under, and on completion compares it with the current value, discarding the result if
they differ. This prevents the most visible failure, the previous song's cover or video appearing
for the new song, without having to cancel anything.

### `init()`

`NowPlaying.swift:67-90`. Three things happen.

**1. Music's distributed notification.** `DistributedNotificationCenter` delivers notifications
between processes. The Music app (and iTunes before it) posts `com.apple.Music.playerInfo` on
every track or state change, with a `userInfo` dictionary that includes `Name`, `Artist`,
`Album`, `Player State` (`"Playing"`, `"Paused"`, `"Stopped"`) and `Total Time` (milliseconds).
Receiving it needs no permission: Himawari is not sandboxed (there is no entitlements file in
`build.sh`), and distributed notifications are not covered by TCC.

```swift
let total = (info["Total Time"] as? Double ?? Double(info["Total Time"] as? Int ?? 0)) / 1000
onMainActor {
    guard let self else { return }
    if state == "Stopped" || name == nil {
        self.set(track: nil, playing: false)
    } else if let name {
        self.set(track: Track(name: name, artist: artist, album: album, duration: total), playing: state == "Playing")
        self.refresh()
    }
}
```
(`NowPlaying.swift:73-82`)

The observer runs on `queue: .main`, and the values are extracted before the `onMainActor` hop.
`Total Time` is read as `Double` or as `Int` and divided by 1000 to get seconds. A stopped player,
or a notification with no `Name`, clears the track. Otherwise the track and play state are set
and `refresh()` is called, which follows up over AppleScript to get the position (the
notification has none) and to correct anything the notification got wrong.

**2. Initial read and ticking.** `refresh()` gets the state at launch. `startTicking()` starts
the one-second timer. Because `tracksPosition` defaults to `true`, the timer always starts here.
`AppDelegate` then sets `tracksPosition = false` right away (`AppDelegate.swift:88`), and the
`didSet` stops it.

**3. The system stream.** If `Bundle.main` has `NowPlayingHelper.dylib`, it creates
`SystemNowPlaying` with a callback that forwards each `State` to `apply(_:)` (capturing `self`
weakly), and starts it.

### `apply(_:)` — a message from the system stream

`NowPlaying.swift:111-129`.

```swift
guard let music = NSRunningApplication.runningApplications(withBundleIdentifier: Self.music).first,
      s.pid == music.processIdentifier, let title = s.title else { return }
systemAt = CACurrentMediaTime()
let playing = s.rate > 0
set(track: Track(name: title, artist: s.artist ?? "", album: s.album ?? "", duration: s.duration), playing: playing)
```
(`NowPlaying.swift:112-116`)

Steps:

1. **Only Music.** The system Now Playing session belongs to whichever app last played media:
   Safari, Spotify, a video in QuickTime. The message is accepted only if its `pid` matches the
   running Music app's process ID and it has a title. Everything else is dropped, including the
   heartbeat while another app owns Now Playing. That means `systemLive` lapses after 12 s and
   the AppleScript path takes over again.
2. Stamp `systemAt`, so `systemLive` becomes true.
3. Playing is `rate > 0`. Set the track and play state through `set(track:playing:)`, which
   resets everything if this is a new song.
4. **The stale-cover guard** (lines 117-124, covered below).
5. **Position.** `age` is how long ago the reading was true: the current Unix time minus
   `timestamp`, clamped at 0 against clock skew. `measuredPosition` is the raw `elapsed`.
   `measuredAt` is the monotonic time *at which it was true*, `CACurrentMediaTime() - age`. This
   converts a Unix-time reading to the monotonic clock without keeping two clocks around. The
   published `position` is moved forward by `age × rate` if playing, and is just `elapsed`
   if paused.

#### The stale-cover guard

```swift
// Right after a skip the system can still hand over the last song's cover: the same
// artwork for a different album is that, not this song's.
let album = s.album ?? ""
let stale = s.artworkID != nil && s.artworkID == shownArtwork?.id && album != shownArtwork?.album
if let data = s.artwork, !stale {
    shownArtwork = (s.artworkID, album)
    useSystemArtwork(data, id: s.artworkID)
}
```
(`NowPlaying.swift:117-124`)

When a song changes, MediaRemote does not update its fields all at once. For a moment the info
dictionary can have the new title and album with the old artwork. A guard based on the
generation counter would not catch this, because the message as a whole really is about the new
song. The guard therefore compares the cover with the album: if the artwork identifier is the
one most recently shown, but the album name differs, the cover belongs to the previous song and
is ignored. Two songs from the same album share a cover, so that case is allowed. When the
identifier is `nil` (local files often have no identifier), the guard cannot judge and the
image is accepted. `shownArtwork` is updated only when a cover is actually used.

Note the interaction with the helper's deduplication. The helper sends image bytes only when
the identifier changes, so a stale pairing with *data* attached mostly happens when the helper
has just (re)started and resends a cover, or when the identifier is missing. The guard is cheap
insurance for those cases.

### `useSystemArtwork(_:id:)`

`NowPlaying.swift:95-108`. Applies a cover from the system stream:

1. Decode with `NSImage(data:)`. If decoding fails, return without changes.
2. `artwork = image` and `systemArtworkGeneration = generation`. The second assignment records
   that this song's cover is the exact one, so the slower AppleScript cover read
   (`loadArtwork`, step 1) will not replace it when it completes.
3. **Sharpen.** If the identifier is an `https://` URL on `mzstatic.com` (Apple's media CDN, which
   serves all iTunes and Apple Music artwork), the size in the file name is replaced. These URLs
   end in a size segment like `/600x600bb.jpg` (`bb` means "bounding box"), and the CDN renders
   the image at whatever size you ask for. The regular expression
   `/\d+x\d+bb\.(jpg|png|webp)$` becomes `/1200x1200bb.jpg`. The Now Playing image is sized for
   Control Center's small tile, while a 1200-px copy is sharp enough to fill a CD on a Retina
   desktop.
4. Download the larger image in a `Task`. If the download succeeds, the image decodes, and
   `generation` hasn't changed, it replaces `artwork`.

The comment explains why the system cover is preferred: for streamed (not downloaded) Apple
Music songs, AppleScript's `artwork 1 of current track` has no data, and an iTunes Search guess
could be the wrong edition of the album. The system's cover is the exact one Music shows.

### Position tracking: `tracksPosition`, `startTicking`, `stopTicking`, `tick`

Updating `position` once a second means a published change once a second, which can trigger
SwiftUI or Combine work in subscribers. Himawari only needs it while a YouTube video follows the
song or the side-bar player is on screen, so `AppDelegate` turns `tracksPosition` on and off
(`AppDelegate.swift:212`). The `didSet` starts or stops the timer only when the value actually
changes.

`startTicking()` (lines 133-138) is idempotent (`guard timer == nil`). It schedules a repeating
1 s `Timer` on the main run loop, whose block hops into a `Task { @MainActor }` to call `tick()`.
`stopTicking()` invalidates the timer and sets it to nil.

`tick()` (lines 145-154):

```swift
guard isPlaying, tracksPosition else { return }
if systemLive { // exact: from the last pushed reading, no need to ask Music
    position = min(measuredPosition + (CACurrentMediaTime() - measuredAt), track?.duration ?? .infinity)
    return
}
position = min(position + 1, track?.duration ?? .infinity)
ticks += 1
if ticks % 5 == 0 { refresh() }
```

There are two modes. With the system stream live, position is worked out from the last exact
reading (`measuredPosition` plus monotonic time since `measuredAt`), so it never drifts, and
there is no need to ask Music. Without it, the position goes up by one per tick, and every fifth
tick `refresh()` asks Music for the true value. In both modes the position is capped at the
track's duration. The rate is assumed to be 1 while playing in the extrapolation.

| Source of truth | Precision | Cost while playing |
|---|---|---|
| MediaRemote push (`apply`) | exact, timestamped | none (push) |
| AppleScript `timedScript` (`refresh`) | ±half the script's round trip | one Apple event per 5 s |
| Counting ticks | drifts up to 5 s between refreshes | timer only |

`measuredPosition`/`measuredAt` are public for clients that run their own smooth clock (the
CD scene's progress, `AppDelegate.songPosition()` at line 218, and `SongInfo`). They don't need
the one-second `position` publisher at all.

### Controls

All controls send AppleScript to Music through `tell(_:block:)`, which runs `osascript` in a
child process and calls `refresh()` when it finishes, so the published state follows the change
quickly even without the system stream.

| Method | AppleScript sent | Notes |
|---|---|---|
| `playPause()` | `playpause` | |
| `pause()` | `pause` | Used for the gear's "stop" button |
| `next()` | `next track` | |
| `previous()` | `previous track` | |
| `seek(to:)` | `set player position to <s>` | Formatted `%.1f`; moves `position`, `measuredPosition`, `measuredAt` immediately so the bar doesn't wait |
| `setVolume(_:)` | `set sound volume to <0…100>` | Clamped; this is Music's own volume, not the system output volume |
| `setRepeat(_:)` | `set song repeat to all` / `off` | "on" means repeat all; repeat-one can be read but not set |
| `setShuffle(_:)` | `set shuffle enabled to true/false` | |
| `openMusic()` | — | `NSWorkspace.openApplication` with Music's URL from its bundle ID; launches or brings it forward |
| `fetchVolume(_:)` | `return sound volume as text` | Through `osascript`, result parsed as `Int` |

Scripts address Music by bundle ID (`tell application id "com.apple.Music"`), not by name. That
works whatever language the system is in and whatever the app is called locally.

**AppleScript and TCC.** Sending Apple events to another app is controlled by the
Transparency, Consent and Control (TCC) "Automation" permission. The first time Himawari sends
an event to Music, macOS shows "Himawari wants access to control Music", using the
`NSAppleEventsUsageDescription` string in `Resources/Info.plist`. If the user denies it, every
script fails with an error. `osascript` exits non-zero and `NSAppleScript` returns an error
dictionary, and both paths turn that into a `nil` result, which the callers ignore.

#### `Deck`, `tonePreset`, `fetchDeck(_:)`

`Deck` (lines 180-189) is the state of the side gear (the widget-like control on the
wallpaper) apart from the song:

| Field | Type | Meaning |
|---|---|---|
| `volume` | `Double` | Music's volume, 0…1 |
| `repeating` | `Bool` | Repeat is "all" or "one" |
| `shuffling` | `Bool` | Shuffle on |
| `bass`, `treble` | `Double` | dB, −12…12; nonzero only when Himawari's preset is the active one |
| `equalizerOn` | `Bool` | Music's EQ enabled, recorded so turning both knobs back to 0 can restore it |
| `preset` | `String` | Name of the current EQ preset |

`tonePreset` is `"Himawari"`, the name of the equalizer preset the knobs edit. Music has no
"bass" or "treble" setting of its own, only a 10-band graphic equalizer with named presets, so
Himawari creates its own preset and shapes it.

`fetchDeck` (lines 194-218) reads everything in a single Apple event using `timedScript`. Inside
a `try`, it reads the current EQ preset's name and, only if the EQ is enabled *and* the preset is
`Himawari`, bands 1 and 10 as bass and treble. Without that check, a user's "Rock" preset would
show up as knob positions. It returns seven fields joined with `\u{1F}`, the ASCII Unit
Separator. Unlike a comma, a tab or a newline, that character cannot plausibly appear in a
preset name. On the Swift side, exactly seven parts are required, or `done(nil)` is called.
Numbers go through `replacingOccurrences(of: ",", with: ".")`, because AppleScript's `as text`
formats reals using the user's locale (`3,5` in German). `song repeat as text` is `off`, `one` or
`all`, and anything other than `off` counts as repeating.

`AppDelegate.refreshDeck()` calls this when the song changes and every 3 s while the gear is
visible (`AppDelegate.swift:136-142`), since repeat and shuffle can also be changed in Music.

#### `setTone(bass:treble:restore:)`

`NowPlaying.swift:225-250`. It converts two knob values into the 10-band EQ:

1. Clamp both to −12…12 dB.
2. **Both at about 0** (|v| < 0.25 dB): put back the user's equalizer. The preset to restore
   is `restore.preset`, unless that is empty or is `Himawari` itself, in which case it is
   `"Flat"`. Selecting it is wrapped in `try` (the preset may have been deleted), and the
   EQ-enabled state is put back as `restore.on && restore.preset != "Himawari"`. Double quotes in
   the preset name are escaped for the AppleScript string literal. `AppDelegate.setTone` saves
   the restore values in `UserDefaults` (`toneRestoreOn`, `toneRestorePreset`) the first time the
   Himawari preset takes over (`AppDelegate.swift:235-239`).
3. **Otherwise build shelves.** Music's ten bands are at 32, 64, 125, 250, 500 Hz and 1, 2, 4, 8,
   16 kHz. The band array is `[b, b, b/2, 0, 0, 0, 0, t/2, t, t]`: bass fully on the two lowest
   bands and half on 125 Hz, treble half on 4 kHz and fully on 8 and 16 kHz, with 250 Hz to 2 kHz
   untouched. This approximates a low shelf and a high shelf.
4. **Preamp headroom.** `preamp = -max(b, t, 0) / 2`. A boost of +12 dB on some bands would clip
   loud masters, so the preamp drops by half the largest boost. Cuts need no headroom, hence
   the `0` in `max`.
5. One script, sent as a `tell … end tell` block: create the `Himawari` preset if it doesn't
   exist, set its ten bands and preamp (each formatted `%.1f`), make it current, and enable the
   EQ.

`AppDelegate.setTone` throttles calls to one every 0.25 s while a knob turns, and sends the final
value 0.3 s after release. The comment there says why: "scripts run side by side, so the final
setting must go after the rest". `osascript` runs on a concurrent global queue, so two scripts
can finish in either order.

#### `tell(_:block:)`

Lines 258-262. It wraps a command as either `tell application id "com.apple.Music" to <command>`
(one line) or a multi-line `tell … end tell` block (`block: true`, needed for multi-statement
scripts like `setTone`). It runs the result with `osascript` and calls `refresh()` on completion.
`self` is captured weakly.

### Reading Music's state: `refresh()`

`NowPlaying.swift:266-291`.

1. If no process with bundle ID `com.apple.Music` is running, clear the track and return. This
   check matters: *any* `tell application "Music"` would launch Music, and Himawari must never
   open Music by itself.
2. Run one script through `timedScript`. If the player is stopped it returns `"stopped"`.
   Otherwise it returns state, name, artist, album, duration and player position, joined with
   `\u{1F}`.
3. In the completion: `nil` output (script error, for example permission denied, or Music
   quitting during the call) changes nothing. Anything other than six parts (that is,
   `"stopped"`) clears the track. Otherwise it sets the track (duration parsed in a
   locale-tolerant way) and `playing` from `parts[0] == "playing"`.
4. **Position only if the system stream is silent.** If `systemLive`, the AppleScript position
   is ignored, because the pushed reading is more precise. Otherwise `measuredPosition` is the
   script's `player position`, `measuredAt` is `readAt` (the midpoint of the Apple event round
   trip, see `timedScript`), and `position` is set to it.

`refresh()` runs at launch, after every distributed notification, after every control command,
and every fifth tick when the stream is down.

### `set(track:playing:)` — the song-change funnel

```swift
private func set(track new: Track?, playing: Bool) {
    isPlaying = playing
    guard new != track else { return }
    track = new
    position = 0
    measuredPosition = 0
    measuredAt = CACurrentMediaTime()
    generation += 1
    youtubeVideos = []
    searching = new != nil
    artwork = nil // never show the last song's cover for this one
    guard let new else { artwork = nil; motionVideo = nil; return }
    loadArtwork(for: new, generation: generation)
}
```
(`NowPlaying.swift:293-306`)

All three track sources go through this function. `isPlaying` is always updated (and
`@Published` emits even when the value is the same). Everything else happens only for a
*different* track, by the duration-blind `==`. A new song resets the position, increments
`generation`, which invalidates every pending lookup, empties the YouTube list, sets `searching`
if there is a song, and clears `artwork` so the old cover never shows against the new song.
Note that `motionVideo` is *not* cleared for a new song. `loadArtwork` sets it, either
synchronously from the cache or to nil before searching. The wallpaper relies on `searching` to
keep the old video or CD on screen during the lookup (`AppDelegate.swift:189-193`). With no song,
`motionVideo` is cleared and loading stops.

Because the funnel ignores repeated reports of the same song, the three sources can report the
same change in any order (distributed notification, then MediaRemote, then the AppleScript
follow-up), and only the first one triggers the reset and the searches.

### `loadArtwork(for:generation:)`

`NowPlaying.swift:308-341`. This is the core of the artwork logic. It starts two lookups at once.

**Step 1, the cover Music has.** One `osascript` run reads `raw data of artwork 1 of current
track` and writes it to `artworkFile` using AppleScript's file I/O (`open for access … with write
permission`, `set eof f to 0` to truncate, `write`, `close access`). It returns `"ok"`. The data
goes through a file because `osascript`'s stdout is text, and AppleScript's text form of binary
data (`«data JPEG…»` hex) would be large and slow to parse. The file name includes the process ID,
so two instances never collide. The completion applies the image only if:
* `generation` hasn't changed,
* the script returned `"ok"` (it errors for songs without local artwork, which includes most
  streamed songs), and
* the system stream has not already supplied this song's cover
  (`systemArtworkGeneration != generation`).

This step covers songs you imported yourself, which the iTunes catalog may not know.

**Step 2, motion artwork and a catalog cover.** The cache key is `artist|album`.
* *Cache hit:* `motionVideo` is set immediately. If there is still no cover, the cached 600-px
  catalog cover is downloaded with `fetchImage`. Then, if there is no video, `findYouTube`
  starts, and if there is one, `searching` becomes false.
* *Cache miss:* `motionVideo = nil`, then a `Task` calls `MotionArtwork.find(artist:album:song:
  duration:)`. The result is stored in the cache *before* the generation check, so a lookup
  that finishes after a skip still benefits the next time that album plays. If the generation
  still matches, it applies the video, the fallback cover and the YouTube step as above.

**Artwork precedence.** In order of priority:

| Priority | Source | Condition |
|---|---|---|
| 1 | System Now Playing cover (`useSystemArtwork`), then its 1200-px `mzstatic` copy | Stream live and Music owns Now Playing |
| 2 | AppleScript `raw data of artwork 1` | No system cover for this generation |
| 3 | iTunes catalog 600-px cover from `MotionArtwork.Result.cover` | Still no `artwork` when the lookup ends (`fetchImage` checks `artwork == nil`) |

Lower-priority sources never overwrite a higher one. A system cover can still arrive after an
AppleScript or catalog cover and replace it, because `useSystemArtwork` does not check
`artwork == nil`.

### `findYouTube(for:generation:)`

Lines 344-355. If `youtubeFallback` is false, clear `searching` and stop. Otherwise look up
`artist|song name` (keyed by *song*, unlike motion artwork, which is per album) in
`youtubeCache`. On a miss, run `YouTubeLoop.findVideos` in a `Task`, cache the IDs whatever the
generation, and apply them and clear `searching` only if the generation still matches. An empty
array is a valid, cached result: "no usable video".

### `fetchImage(_:generation:)`

Lines 357-363. Downloads an image URL with `URLSession.shared` and sets `artwork` only if the
generation matches *and* `artwork` is still nil. A catalog cover never replaces an exact one.

### Running AppleScript: `osascript` and `timedScript`

There are two ways to run scripts, chosen per purpose.

**`osascript(_:completion:)`** (lines 366-386) runs `/usr/bin/osascript -e <source>` as a child
process on a global `.utility` queue. It reads all of stdout, waits for exit, and returns the
trimmed output only if the exit status is 0. stderr goes to the null device. The completion is
boxed in `Completion` and sent back with `DispatchQueue.main.async { onMainActor { … } }`. Because
it is a separate process, a hung Music (for example, Music showing a modal dialog) blocks only
that process and one global-queue thread, never Himawari's main thread and never other scripts.
The cost is about 50-100 ms of process launch per call, which is fine for user-triggered controls
and the per-song artwork read.

**`timedScript(_:completion:)`** (lines 391-406) runs the script inside Himawari with
`NSAppleScript`, on the serial `scriptQueue` (`.userInitiated`):

```swift
scriptQueue.async {
    let script = compiled[source] ?? NSAppleScript(source: source)
    compiled[source] = script
    var error: NSDictionary?
    let before = CACurrentMediaTime()
    let result = script?.executeAndReturnError(&error).stringValue
    let after = CACurrentMediaTime()
    let output = error == nil ? result : nil
    DispatchQueue.main.async { onMainActor { done.run(output, (before + after) / 2) } }
}
```
(`NowPlaying.swift:396-405`)

Two design points. First, *compiled-script caching*: `refresh()` and `fetchDeck()` always send
the same source text, so the compiled `NSAppleScript` is reused from `compiled`, and running it
costs only the Apple event round trip, which is a few milliseconds. Second, *timing*: the
position Music returns was read somewhere between `before` and `after`. The midpoint is the best
estimate, with an error of at most half the round trip. That is the `readAt` that `refresh()`
stores as `measuredAt`. A separate `osascript` process could not be timed this way, since process
launch time is large and variable.

`compiled` is declared `nonisolated(unsafe)` because it is a static mutable dictionary outside
the main actor. That is safe only because every access is on the serial `scriptQueue`.

`Completion` and `TimedCompletion` (lines 408-416) are tiny `@unchecked Sendable` boxes around
`@MainActor` closures. They let a main-actor closure travel through a `DispatchQueue` closure
that Swift 6's checks would otherwise reject. They are safe because the closure only runs on the
main thread.

---

### `MotionArtwork`

A caseless enum used as a namespace. It has no state. Everything is `static`, and the only cache
is `MusicNowPlaying.motionCache`.

**Background: what motion artwork is and where it lives.** Many recent albums on Apple Music have
an animated cover: a short looping video, square or tall, that the Music app shows. It is streamed
with HTTP Live Streaming (HLS) from `mvod.itunes.apple.com`. An HLS *master playlist* (`.m3u8`)
lists several *variant* streams at different resolutions, bitrates and codecs, each with its own
media playlist. The public album page on `music.apple.com` contains the master playlist URLs in
its embedded JSON data. There is no public API that returns them.

#### `Result`

| Field | Type | Meaning |
|---|---|---|
| `video` | `URL?` | HLS master playlist of the motion artwork, nil if none |
| `cover` | `URL?` | 600×600 still cover from the same catalog result |

`Sendable`, so it can be stored in the static cache and returned across `await`.

#### `find(artist:album:song:duration:)`

`NowPlaying.swift:452-474`. The doc comment states the policy: "Only a result that really is that
album counts … no animation beats the wrong one." Showing another album's animation, or the
animation of a same-named single, would be worse than showing none.

1. **Song-first lookup.** If a song name is given, `songAlbum` searches the catalog for the
   *song*. The song's catalog entry links to the album it is on, which is more reliable than
   searching for the album by name (deluxe editions, singles and compilations make album names
   ambiguous). If that gives a page with a video, return it. If it gives a page with no video,
   fall through.
2. If `albumKey(album)` is empty (Music didn't name an album, or the name was only edition
   words), give up with `(nil, nil)`.
3. **Album lookup, per store.** For each store from `stores` (the user's region, then the US),
   query the iTunes Search API:
   `https://itunes.apple.com/search?term=<first artist> <album key>&entity=album&limit=15&country=<store>`.
   Take the first result that is the `sameAlbum` *and* `byArtist`.
4. From the match, build the cover by swapping the `100x100bb` in `artworkUrl100` for `600x600bb`
   (the same `mzstatic` size trick). If there is no `collectionViewUrl`, return just the cover.
   Otherwise return `motion(onAlbumPage:cover:)`. Note that the first store with a matching album
   ends the search, whether or not its page has a video.
5. No store matched: `(nil, nil)`.

**Background: the iTunes Search API.** `itunes.apple.com/search` is Apple's free, documented,
keyless search over the iTunes and Apple Music catalog. It returns JSON with a `results` array.
Each result has fields such as `artistName`, `collectionName`, `trackName`, `trackTimeMillis`,
`artworkUrl100` and `collectionViewUrl` (the album's `music.apple.com` page). `country` selects
the storefront, which matters because catalogs and album titles differ by region. Apple
rate-limits the endpoint, which is one reason results are cached per album.

#### `stores`

Lines 477-481. `["US"]`, with the user's `Locale.current.region` inserted first if it isn't the
US. The user's own store comes first because that is where their song is most likely to be
listed under the same title. The US is the fallback because it has the largest catalog.

#### `catalog(_:)`

Lines 483-487. Fetches the URL built from `URLComponents` (which percent-encodes the query) and
returns `json["results"]` as `[[String: Any]]`. It returns nil on a network error, non-JSON, or a
missing `results`. Callers treat nil as "try the next store".

#### `albumKey(_:)`

```swift
/// "Way Ahead - EP", "Views (Deluxe)", "Scorpion [Explicit]" → "way ahead", "views", "scorpion"
static func albumKey(_ album: String) -> String {
    var a = album.replacingOccurrences(of: #"\s+-\s+(EP|Single)\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
    a = a.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*(Single|EP|Deluxe|Remaster|Edition|Version|Expanded|Explicit|Clean|Bonus)[^\)\]]*[\)\]]"#,
                               with: "", options: [.regularExpression, .caseInsensitive])
    return YouTubeLoop.normalize(a)
}
```
(`NowPlaying.swift:489-495`)

Reduces an album title to a comparison key. It removes a trailing `- EP` / `- Single`, then any
parenthesised or bracketed group that contains an edition word (`(Deluxe Edition)`,
`[2011 Remaster]`, `(Explicit)`), and finally normalises: lowercase, accents removed, punctuation
turned into spaces, whitespace collapsed. Groups without an edition word, such as
`(Original Motion Picture Soundtrack)`, are kept. It is `internal` (not `private`) so it can be
unit-tested.

#### `sameAlbum(_:_:)`

Lines 498-502. Two titles are the same album if their keys are equal, or if one key followed by a
space is a prefix of the other. That accepts `"views"` against `"views bonus track version"`
(which the bracket rule may not have removed), but not `"intro"` against `"introspection"`. Empty
keys never match. Also `internal` for testing.

#### `byArtist(_:_:)`

Lines 504-507. True if the result's normalised `artistName` *contains* any of the names from
`YouTubeLoop.artistNames(artist)`. `contains` rather than `==`, so `"drake"` matches
`"drake future"` (the catalog's name for a collaboration).

#### `songAlbum(artist:song:album:duration:)`

`NowPlaying.swift:511-539`. Finds the album page through the song.

1. `wanted` is the normalised song title. If it is empty, return nil.
2. `knowAlbum` is whether Music gave an album name that has a non-empty key.
3. For each store, search `entity=song&limit=25` for `"<first artist> <song>"`.
4. Filter the candidates. The track name must equal `wanted`, or start with `wanted + " "`
   (allowing `"song feat x"` or `"song remastered"`), and the result must be by the artist.
   Then:
   * if the album is known, the result's `collectionName` must be the `sameAlbum`;
   * if not, the durations must be within 3 s (`trackTimeMillis / 1000` against Music's
     duration). This identifies the right recording when there is no album name, and rejects
     everything when the duration is 0.
5. Pick the best candidate with `min`, ordering by the tuple (exact title ? 0 : 1, |length
   difference|): exact titles first, then the closest length.
6. Return the match's `collectionViewUrl` and its 600-px cover. If no candidate matched, try the
   next store.

Searching by song is what stops the "Intro" problem mentioned in the doc comment: many artists
have a track called "Intro" on several albums, and a song search with an album check finds the
one on the current album.

#### `motion(onAlbumPage:cover:)`

`NowPlaying.swift:541-557`. Gets the video URL from the album page.

1. Request the page with a desktop Safari `User-Agent`. Without one, `music.apple.com` may serve
   a reduced page or a redirect.
2. If the fetch fails or isn't UTF-8, return `(nil, cover)`.
3. Pattern: `https://mvod\.itunes\.apple\.com/[^"\\\s]+?\.m3u8`, a lazy match up to the first
   `.m3u8` that stops at a quote, backslash or whitespace.
4. **Prefer the square loop.** Album pages can list both a tall (`motionDetailTall`) and a square
   (`motionDetailSquare`) video. The square one matches a cover and the CD scene. If
   `"motionDetailSquare"` appears, the first matching URL within the next 2,000 characters is
   used.
5. Otherwise, use the first motion video URL anywhere on the page, which may be the tall version.
6. Return it with the cover.

This is screen scraping, as the file comment admits. Its failure mode is benign: if Apple
renames the key, it falls back to "any video", and if the URLs are encoded differently, it falls
back to "no video", which shows the still cover or a YouTube loop.

#### `bestVariant(of:maxSide:)`

`NowPlaying.swift:424-442`. Called by `WallpaperManager` before starting a motion video, with
`maxSide` equal to the largest screen's longer side in pixels (capped at 1080 in Battery Saver,
`WallpaperManager.swift:148-149`).

The doc comment gives the reason: AVPlayer's adaptive streaming starts on a low-bitrate variant
and moves up as it measures bandwidth. A motion artwork loop is about 20 seconds, so it ends and
restarts before the player ever moves up, and the wallpaper would stay blurry. Picking one fixed
variant avoids that.

Steps:

1. Download the master playlist. If that fails, return the master unchanged, so AVPlayer can
   still play it adaptively.
2. For each `#EXT-X-STREAM-INF` line with a following line:
   * get `RESOLUTION=WxH`;
   * get `BANDWIDTH=n` with the lookbehind `(?<![-A-Z])`, so that `AVERAGE-BANDWIDTH=` is not
     matched by mistake;
   * resolve the next line (the variant's URI) relative to the master URL;
   * record (longer side, whether `CODECS` mentions `hvc1`, i.e. HEVC, bandwidth, absolute URL).
   Entries with no resolution are skipped.
3. Keep the variants whose longer side is at most `maxSide × 1.15`. The 15 % allowance accepts,
   for example, a 2160-px variant for a 2048-px screen instead of falling back to 1440.
4. If none fit, use the single smallest variant.
5. Pick the maximum by the tuple (side, HEVC ? 1 : 0, bandwidth): the largest that fits, HEVC
   over H.264 at equal size (better quality per bit, and decoded in hardware on every supported
   Mac), and then the highest bitrate.
6. Return its URL, or the master if no variants were parsed.

```
master.m3u8
 ├─ 3840x3840 hvc1 25 Mb/s   ✗ > maxSide·1.15
 ├─ 2048x2048 hvc1 12 Mb/s   ✓  ◄── chosen (largest fitting, HEVC)
 ├─ 2048x2048 avc1 14 Mb/s   ✓  (same side, not HEVC)
 └─ 1080x1080 avc1  5 Mb/s   ✓
```

---

### `YouTubeLoop`

Another caseless namespace enum. It holds the YouTube search plus two text helpers that
`MotionArtwork` also uses.

#### `findVideos(artist:title:)`

`NowPlaying.swift:568-612`. The file comment explains the approach: YouTube's official Data API
needs an API key and has quotas, so Himawari reads the public search results page. It uses the
embedded player to play the video, which avoids downloading videos (that would break YouTube's
terms). Steps:

1. Build `https://www.youtube.com/results?search_query=<artist> <title> official video`, with a
   desktop Safari User-Agent and `Accept-Language: en-US`. The language header keeps titles and
   page structure predictable.
2. Find the JSON blob that the page assigns to `var ytInitialData = ` and ends with
   `;</script>`, and parse it.
3. Walk the whole JSON tree recursively (nested function `walk`), collecting every
   `videoRenderer` object's `videoId`, title and channel name. Title and channel text are stored
   as `{runs: [{text: …}, …]}`, and `runs(_:)` joins them. Walking the whole tree rather than a
   fixed path makes it tolerant of YouTube rearranging the page.
4. Score each video. These checks reject it:
   * the normalised title must contain the normalised song title;
   * the title or channel must contain one of the artist names;
   * the title must not contain any of `reaction, tutorial, cover, karaoke, slowed, reverb, 8d,
     nightcore, instrumental, how to`.

   These adjust the score:

   | Signal | Score |
   |---|---|
   | Title has "official video", "official music video" or "music video" | +3 |
   | Channel contains an artist name, "vevo", "records" or "def jam" | +2 |
   | Title has "lyric" | −2 (mostly text on screen) |
   | Title has "live" | −1 |

5. Sort by score (descending), remove duplicate IDs (keeping the first), and return at most
   four. Several are returned because some videos have embedding disabled. `YouTubeLoopView`
   moves to the next one when the player reports an error.

#### `runs(_:)`

Lines 614-616. Joins the `text` of each run in a YouTube text object. Returns `""` if the shape
doesn't match.

#### `normalize(_:)`

Lines 619-623. Folds case and diacritics (`folding(options: [.caseInsensitive,
.diacriticInsensitive])`), replaces every scalar that isn't in `CharacterSet.alphanumerics` with a
space, and collapses runs of spaces. `"Kheench Maari!"` becomes `"kheench maari"`. Because
`alphanumerics` includes letters from all scripts, Devanagari, Japanese and other non-Latin titles
are kept rather than removed.

#### `artistNames(_:)`

Lines 626-629. Splits a credit string on ` feat. `, ` ft. `, ` featuring `, ` x `, ` & ` and
` and ` (case-insensitive, needing whitespace on both sides), as well as on commas. It
normalises each part and drops parts shorter than two characters.
The doc comment says `"Raga, DG IMMORTALS & X feat. Y"` becomes `["raga", "dg immortals", "x", "y"]`, but
the `count >= 2` filter drops `"x"` and `"y"`, so the real result is `["raga", "dg immortals"]`.

---

### `YouTubeLoopView`

An `NSView` that shows a muted YouTube video on loop, filling its frame or matching its width.
`WallpaperManager.addYouTube(to:)` creates one per wallpaper window
(`WallpaperManager.swift:485-496`). It lives as long as the YouTube override is on and is removed
with its window's content.

| Property | Type | Meaning |
|---|---|---|
| `web` | `WKWebView` | The page hosting the iframe player |
| `ids` | `[String]` | Video IDs currently loaded |
| `fill` | `Bool` | Crop to cover the frame (true) or show full width (false, the wallpaper's "Fit Width") |

It is main-thread only, like all AppKit views.

**`init(ids:fill:)`.** `mediaTypesRequiringUserActionForPlayback = []` allows autoplay without a
click, which WebKit allows for muted video. `setValue(false, forKey: "drawsBackground")` is the
long-standing key-value-coding way to make a `WKWebView` transparent on macOS (it is not public
API). The web view autoresizes with the view. The init then calls `show(ids)`.

**`layout()`.** Fits `web` to `bounds`, then sets `pageZoom = min(1, shortSide / 220)`. YouTube's
player refuses to play in a frame smaller than about 200×200 CSS pixels. On a small frame (the
72-pt cover in a widget) the page is laid out at 220 pt and scaled down to fit.

**`hitTest(_:)`** returns nil, so clicks go through the video to whatever is behind it. The
wallpaper must not respond to clicks on the video.

**`show(_:)`** reloads only when the IDs differ and are not empty. It writes an HTML page that:

* makes the body black, with no margin and no scrolling;
* centres the iframe with `translate(-50%,-50%)` and sizes it so a 16:9 video covers the frame
  (`width:max(100vw,177.78vh); height:max(100vh,56.25vw)`, where 177.78 = 100·16/9 and 56.25 =
  100·9/16), or, in fit mode, `100vw × 56.25vw`;
* loads `https://www.youtube.com/iframe_api` and creates a `YT.Player` with `autoplay, mute,
  controls:0, disablekb, fs:0, iv_load_policy:3` (no annotations), `playsinline, rel:0`;
* `ready()` mutes, seeks to a pending `target` if one exists, plays or pauses according to
  `wantPlay`, and sets a 1 s interval: if no song position is being followed (`target === null`)
  and the video has ended (state 0), it seeks to 0 and plays, so the video loops;
* `sync(t, p)` sets the target time and the play state, seeks only if the player is more than
  1.5 s away (seeking on every update would stutter), and plays or pauses;
* `next()`, the `onError` handler (embedding disabled, video removed), destroys the player,
  creates a fresh `#p` div and tries the next ID;
* `setPlaying(p)` plays or pauses without seeking.

The page is loaded with `baseURL: https://localhost/` because the iframe API checks the
embedding page's origin and will not run from `about:blank`.

**`setPlaying(_:)`** and **`sync(to:playing:)`** call those JavaScript functions with
`evaluateJavaScript`. `AppDelegate`'s `$position` subscriber calls
`WallpaperManager.syncYouTube`, which calls `sync` on each view about once a second while
`tracksPosition` is on, so the video's motion follows the song.

---

### Sequence: a song change

The diagram shows a skip from song A (album X) to song B (album Y) with the helper running,
nothing cached, and B's album having motion artwork. Time runs downward.

```
User/Music        Music.app            perl+helper        MusicNowPlaying (main)         Background / Web
    │  ▶▶ next           │                    │                     │                              │
    │──────────────────►│                    │                     │                              │
    │                   │─ distributed note ─┼────────────────────►│ init observer                 │
    │                   │  playerInfo(B, Playing, Total Time)      │ set(track:B) → generation=N+1 │
    │                   │                    │                     │  artwork=nil, searching=true  │
    │                   │                    │                     │  loadArtwork(B, N+1):         │
    │                   │                    │                     │──osascript: raw data of art──►│ (child process)
    │                   │                    │                     │──Task MotionArtwork.find ────►│
    │                   │                    │                     │ refresh() ──timedScript──────►│ scriptQueue
    │                   │─ MediaRemote ─────►│ InfoDidChange       │                              │
    │                   │                    │ emit(): title B,    │                              │
    │                   │                    │ artworkID(A) ⚠      │                              │
    │                   │                    │── JSON line ───────►│ apply(): same track → no reset│
    │                   │                    │                     │  stale guard: id==A, album Y≠X│
    │                   │                    │                     │  → cover ignored              │
    │                   │                    │                     │  measuredPosition/At set      │
    │                   │                    │── JSON line ───────►│ apply(): artworkID(B)+data    │
    │                   │                    │  (cover changed)    │  useSystemArtwork → artwork   │
    │                   │                    │                     │  systemArtworkGeneration=N+1  │
    │                   │                    │                     │──GET mzstatic …/1200x1200bb ─►│
    │                   │                    │                     │◄─ timedScript result ─────────│ systemLive → position ignored
    │                   │                    │                     │◄─ osascript cover "ok" ───────│ ignored (system cover is exact)
    │                   │                    │                     │◄─ 1200 px image ──────────────│ generation N+1 → artwork = big
    │                   │                    │                     │                              │ find: songAlbum (iTunes song search)
    │                   │                    │                     │                              │  → album page → motion() scrape
    │                   │                    │                     │◄─ Result(video, cover) ───────│ motionCache["artist|Y"] = result
    │                   │                    │                     │ motionVideo = m3u8            │
    │                   │                    │                     │ searching = false             │
    │                   │                    │                     │                              │
    │            AppDelegate.applyMusicWallpaper (Combine) → WallpaperManager.setOverride(m3u8)    │
    │                   │                    │                     │      → MotionArtwork.bestVariant → AVPlayer
```

If song B's album has no motion artwork, `find` returns `video: nil`, and `findYouTube` runs
`YouTubeLoop.findVideos`. `searching` stays true until the IDs arrive, and then the wallpaper
shows a `YouTubeLoopView`, or the CD scene if the list is empty or YouTube is turned off. If the
user skips again while any of this is in flight, `generation` becomes N+2, and every late
completion above fails its generation check and changes nothing, apart from writing to the
caches.

Without the helper (debug build, or a future macOS that blocks perl), the MediaRemote column
disappears. The track still comes from the distributed notification, the position from
`refresh()`, and the cover from AppleScript or the catalog.

### Notes and risks

* `NowPlaying.swift:68`: the observer token returned by `addObserver(forName:…)` is discarded, so
  the observer can never be removed. That is harmless for a single app-lifetime instance, but a
  second instance would leave a live block behind.
* `NowPlaying.swift:312`: the AppleScript cover read asks for `current track` *when the script
  runs*, not for the track `loadArtwork` was called for. If Music has not finished switching when
  the script runs, the previous song's cover can be read and accepted under the new generation.
  A system cover, when one arrives, overrides it.
* `NowPlaying.swift:61-62`: the temporary cover file is never deleted, and all calls share it.
  Two overlapping scripts write the same path.
* `NowPlaying.swift:303-304`: `artwork = nil` is assigned twice when `new` is nil (redundant).
  `motionVideo` keeps the previous song's video until `loadArtwork` runs, which is intended for
  the "keep showing during search" behaviour, but it means `motionVideo` alone does not tell you
  which song it belongs to.
* `NowPlaying.swift:324`: the motion cache key `artist|album` is `"artist|"` for every album-less
  song by that artist. `find` returns `(nil, nil)` in that case unless the song search succeeds,
  and a successful song-specific result would then be reused for that artist's other album-less
  songs.
* `NowPlaying.swift:335`, `:350`: failed lookups (network down, rate-limited by the iTunes API)
  are cached as "no video" for the rest of the session. The static caches never shrink.
* `NowPlaying.swift:99-107`: the 1200-px download checks only `generation`. If a second, different
  system cover arrives in the same generation, an older download that finishes later replaces it.
* `NowPlaying.swift:111-113`: `apply` runs `NSRunningApplication.runningApplications(…)` for
  every message, including heartbeats. That is cheap, but it is done on the main thread.
* `NowPlaying.swift:148`: extrapolation assumes rate 1 while playing. A non-1 rate reported by
  MediaRemote is used in `apply` but not in `tick`.
* `NowPlaying.swift:368`: `osascript` scripts run on a concurrent global queue, so control
  commands can complete out of order. `AppDelegate` works around this for tone (0.3 s final
  delay) and volume (throttle), but not for, say, rapid next/previous.
* `NowPlaying.swift:392-401`: `NSAppleScript` is used off the main thread. Apple has
  historically documented `NSAppleScript` as main-thread-only. Here it is confined to one serial
  queue, which works in practice but is outside the documented guarantee.
* `NowPlaying.swift:232`: the preset name escaping handles `"` but not backslashes, so a preset
  name containing `\` would break the script. The `try` block contains the failure.
* `NowPlaying.swift:456`: when the song search finds the album page but it has no video, the album
  search usually finds the same album and fetches the same page again. One wasted request per
  song without motion artwork.
* `NowPlaying.swift:468-471`: the first store with a matching album ends the search, even if its
  page has no video and the next store's page would have one.
* `NowPlaying.swift:547-556`: page scraping depends on literal `https://mvod.itunes.apple.com/…`
  strings in the HTML. If Apple escapes slashes (`\/` or `/`) in its embedded JSON, no video
  is ever found. The failure is silent.
* `NowPlaying.swift:597`, `:607`: rejection and penalty words are matched as substrings: "cover"
  rejects "discover" or "recover", and "live" penalises "alive" or "deliver".
* `NowPlaying.swift:627-628`: in `artistNames`, a lone ` X ` used as a name (for example
  `"Lil Nas X & Y"`) is consumed by the ` x ` separator, giving `"lil nas"` and a one-letter
  `"y"`, which the length filter drops. One-letter artists are never matched.
* `NowPlaying.swift:668`: video IDs are inserted into JavaScript without escaping. They come from
  YouTube's own JSON and are normally `[A-Za-z0-9_-]{11}`, but a malformed value would break or
  inject into the page script.
* `NowPlaying.swift:687`: each player created by `next()` adds another `setInterval`. The intervals
  pile up (harmless, since they all act on the current `player`). When every ID fails, the view
  stays black.
* `NowPlaying.swift:646`: `drawsBackground` is set through private KVC on `WKWebView`. A future
  WebKit could drop the key and raise an exception.
