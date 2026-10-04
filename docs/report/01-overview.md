# 1 · What Himawari is and how it's put together

This chapter is the map for the rest of the report. It says what Himawari does for the person
using it, which processes run when it is on, how the source tree is split into Swift Package
targets, what every file in the repository is for, how the windows are stacked on the desktop,
how data moves between the parts, which threads do the work, what gets written to disk, and
which outside services are contacted. Later chapters take each file in turn; here the aim is
the shape of the whole.

The description is of the repository at commit `22c0feb`, two small fix commits past the
`v1.1.3` tag (`cbebb05`), with `Resources/Info.plist` at version 1.1.3 (build 5). Line counts
below are for those files.

## The product

Himawari (ひまわり, "sunflower") is a macOS menu-bar app for macOS 14.4 or later that puts a
moving picture behind the desktop icons. It started as a port of the GNOME extension "Hanabi"
(the README credits Jeff Shee's `gnome-ext-hanabi`), and the old name survives in the
repository directory (`hanabi-mac`), the signing identity ("Hanabi Local Code Signing"), the
maintenance job's launchd label and in `install.sh`'s one-time migration from `Hanabi.app`.

What a user sees:

| Feature | What it does | Main code |
|---|---|---|
| Live video wallpaper | Any `.mp4` / `.mov` / `.m4v` chosen from the menu loops seamlessly behind the desktop icons on every screen, from one decoder. It pauses when the user pauses it, when the screen is locked or asleep, on battery (optional) and when windows cover every screen (optional). | `WallpaperManager`, `VideoCanvas`, `PlaybackMonitor` |
| Apple Music animated covers | While the Music app plays a song whose album has Apple Music "motion artwork", that looping cover video replaces the user's wallpaper. Himawari finds it through Apple's public iTunes Search API and the album's public web page, then streams the HLS video. | `MusicNowPlaying`, `MotionArtwork` (in `NowPlaying.swift`) |
| Side gear ("rack") | Next to a square cover video, the bars left and right are drawn as retro hi-fi: a CD deck (display, progress ladder, transport buttons, jog wheel) and a stereo analyzer (two VU meters, a 10-band spectrum, VOLUME / BASS / TREBLE knobs, REPEAT / SHUFFLE lamps). Meters follow the real audio through a Core Audio process tap, or animate by themselves if the tap is not allowed. | `NowPlayingSides`, `AudioLevels`, `AudioPermission` |
| CD scene | When the album has no animation (and the YouTube option is off), the cover is printed onto a CD that spins over a glow in the cover's colours, with small characters running along the bottom. Skipping slides discs in from the right; Previous brings the last one back from the left. | `MusicScene`, `DiscPrint`, `AmbientFill` |
| Playable gear and CD | The transport buttons, progress ladder, jog wheel, knobs, REPEAT / SHUFFLE and the disc itself respond to clicks and drags and send commands to Music. Turning the disc scrubs, with a synthesized scratch sound. | `GearControls` |
| YouTube fallback (opt-in) | With "…or a YouTube Loop of the Song" on, an album without motion artwork shows the song's music video in YouTube's embedded player, muted and kept in step with the song position. | `YouTubeLoop`, `YouTubeLoopView` (in `NowPlaying.swift`) |
| Desktop clock | A large, see-through clock on the desktop that changes its ink (light or dark, more contrast over busy pictures) according to what is behind it. Left-click cycles the format (12-hour, 24-hour, Swatch Internet Time, French decimal time, in words); right-click opens its options. It is a separate helper app inside `Himawari.app`. | `HimawariClock` target, `ToneReporter`, `WallpaperTone` |
| Hide desktop files | Clicking an empty spot on the desktop (or ⌃⌥⌘D) raises the wallpaper above Finder's icons; a click on it puts the icons back. | `DesktopPeek`, `WallpaperManager.setClear` |
| Lock screen | "Show Wallpaper on Lock Screen (Still)" sets a frame of the video as the macOS desktop picture, which the lock and login screens show. "Moving Lock Screen" replaces the video files of the Aerials the user picked in System Settings with a 4K HEVC 240 fps conversion of their own video, keeping Apple's originals to put back. | `LockScreen`, `MovingLockScreen` |

There is no main window. The status item (a sunflower drawn in code) holds the only menu, and
an optional Dock icon offers the same menu on right-click.

## The process model

Three kinds of code run when Himawari is on. Each is a separate process, so a crash in one does
not take the others down.

```
 launchd / Finder / login item
          │ opens
          ▼
 ┌───────────────────────────────┐   Process(): --parent <pid>    ┌──────────────────────────────┐
 │ Himawari.app/Contents/MacOS/  │ ─────────────────────────────▶ │ Contents/Helpers/Desktop     │
 │ Himawari  (menu bar, windows, │ ◀── distributed notifications ─▶│ Clock.app/…/HimawariClock    │
 │ AVPlayer, AppleScript)        │    settings changed / tone      │ (one window: the clock)      │
 └───────────────────────────────┘                                 └──────────────────────────────┘
          │ Process(): /usr/bin/perl -e <glue> NowPlayingHelper.dylib
          │ stdin kept open; stdout = JSON lines
          ▼
 ┌───────────────────────────────┐
 │ /usr/bin/perl, with           │  dlopen(MediaRemote.framework)
 │ NowPlayingHelper.dylib loaded │  → one JSON line per Now Playing change + 5 s heartbeat
 └───────────────────────────────┘
          plus short-lived /usr/bin/osascript children (Music, Finder) and /bin/launchctl once
```

**Himawari** (`Sources/Himawari`, bundle id `local.dhairyabhatia.himawari`) is the app proper.
It is an `LSUIElement` agent with activation policy `.accessory` (no Dock icon, no menu bar of
its own) unless "Show in Dock" is on. It owns the wallpaper windows, the AVFoundation player,
the Music connection and the click catchers.

**HimawariClock** (`Sources/HimawariClock`, bundle id `local.dhairyabhatia.desktop.clock`,
display name "Desktop Clock") is a second executable that `build.sh` wraps in its own `.app` and
places at `Himawari.app/Contents/Helpers/Desktop Clock.app`. `ClockHelper` starts it with
`Process` when Himawari finishes launching and passes `--parent <Himawari's pid>`. The clock
polls `kill(parent, 0)` every 3 s and exits when the parent is gone
(`Sources/HimawariClock/main.swift:15-20`), so even a crash of Himawari does not leave an
orphaned clock. In the other direction, `ClockHelper` restarts the clock if it dies, at most three
times a minute, and sends it SIGTERM on quit; `runBackgroundService` in HimawariKit turns
SIGTERM into a clean `exit(0)`. Before this layout, the clock was a launchd agent belonging to a
"Desktop Shell" suite; `ClockHelper.retireOldService` boots that agent out and deletes its plist
and app once.

**NowPlayingHelper** is not an executable at all. macOS only lets Apple-signed programs read
the system Now Playing state through the private MediaRemote framework, so Himawari ships a
small Objective-C dynamic library (`helpers/NowPlayingHelper.m`, compiled by `build.sh` into
`Contents/Resources/NowPlayingHelper.dylib`) and loads it into Apple's own `/usr/bin/perl`. A
three-line Perl script (`SystemNowPlaying.glue`) uses `DynaLoader` to `dlopen` the dylib, find
the C symbol `himawari_now_playing` and call it as a Perl XSUB. That function registers for
MediaRemote's notifications and prints one JSON object per line on stdout: title, artist, album,
duration, elapsed time, rate, timestamp, the artwork identifier, and the artwork bytes (base64)
only when the cover changes. It exits when its stdin reaches end-of-file, which happens when
Himawari, holding the write end of that pipe, goes away. `SystemNowPlaying` restarts it up to five
times with a growing delay and otherwise falls back silently to AppleScript polling. The README
credits `ungive/mediaremote-adapter` for the technique.

Short-lived children: `/usr/bin/osascript` for most Music commands and for asking Finder about
its selection (one process per command, run off the main thread), and `/bin/launchctl bootout`
once for the legacy clock service.

## Targets and modules (Package.swift)

`Package.swift` (14 lines, tools version 5.10, so Swift 5 language mode) declares three targets
and no external dependencies:

| Target | Kind | Path | Depends on | Ends up as |
|---|---|---|---|---|
| `HimawariKit` | library (static, linked into both executables) | `Sources/HimawariKit` | — | code inside both binaries |
| `Himawari` | executable | `Sources/Himawari` | HimawariKit | `Himawari.app/Contents/MacOS/Himawari` |
| `HimawariClock` | executable | `Sources/HimawariClock` | HimawariKit | `…/Helpers/Desktop Clock.app/Contents/MacOS/HimawariClock` |

The platform is given as `.macOS("14.4")` because the `SupportedPlatform` enum has no `v14_4`
case; 14.4 is the first release with Core Audio process taps (`CATapDescription`,
`AudioHardwareCreateProcessTap`), which `AudioLevels` needs. The Objective-C helper is outside
SwiftPM entirely: `build.sh` calls `clang` on it directly.

HimawariKit holds what both processes need (settings, the tone protocol, desktop window
helpers, power state, `onMainActor`), plus `MusicNowPlaying`, which only Himawari uses today. It
also still carries code from the time the same kit served the "Desktop Shell" services (a
Ghostty launcher, full-screen detection, key synthesis, Aero SwiftUI views, layout zones); see
the file map.

A name collision matters when reading the code: both `Sources/Himawari/Settings.swift` and
`Sources/HimawariKit/Settings.swift` declare a class `Settings`. Inside the Himawari target the
local one wins, so `Settings.shared` is the wallpaper settings (domain
`local.dhairyabhatia.himawari`) and the shared clock settings must be written
`HimawariKit.Settings.shared` (domain `local.dhairyabhatia.desktop`). Chapter 3 covers both.

## File map

Every file tracked in git, plus the two ignored directories that matter. Lines are `wc -l`.

### Sources/Himawari (the app, 4,835 lines)

| File | Lines | Purpose |
|---|---|---|
| `main.swift` | 11 | Entry point: creates `NSApplication`, sets `AppDelegate`, `.accessory` policy, runs the app. |
| `AppDelegate.swift` | 608 | Launch sequence, status-item and Dock menus, hotkeys, wiring of Music state to the wallpaper and of gear actions to Music commands. |
| `Settings.swift` | 120 | Wallpaper settings in `UserDefaults.standard`; the `VideoSizing` and `BarFill` enums. |
| `Log.swift` | 25 | Appends de-duplicated lines to `~/Library/Logs/Himawari.log`, trimming it past 1 MB. |
| `WallpaperManager.swift` | 585 | One `AVQueuePlayer`, one wallpaper window per screen; chooses between the user's video, motion artwork, YouTube and the CD scene; loops, retries, tone sampling, audio meters on/off, click catchers. |
| `VideoCanvas.swift` | 156 | One screen's content view: two `AVPlayerLayer`s of the same player (sharp video and a cheap blurred backdrop), the ambient fill, the side gear; computes the video frame for each sizing mode. |
| `AmbientFill.swift` | 161 | `AmbientPalette` (darkened edge colours of a frame) and `AmbientLayer` (slowly drifting colour blobs in the bars). |
| `NowPlayingSides.swift` | 933 | `SongInfo` and the side gear: the CD deck and stereo analyzer drawn once into an image, with animated display, needles, spectrum and jog wheel; exposes control rectangles. |
| `MusicScene.swift` | 662 | The spinning-CD scene: disc, sheen, glow, runners, arrival/leave/change-disc animations, disc grabbing. |
| `DiscPrint.swift` | 106 | Pure function that prints a cover onto a disc image (placement away from busy detail, data-track rings), run on a background queue. |
| `GearControls.swift` | 342 | Invisible `NSPanel` "catchers" over each gear control and the disc; converts clicks and drags to `Action`s; `ScratchSound` synthesizer. |
| `AudioLevels.swift` | 275 | Core Audio process tap on Music plus a private aggregate device (rebuilt if Music relaunches or the output device changes); RMS and 10-band FFT on its own queue. |
| `AudioPermission.swift` | 43 | Preflight / request of the `kTCCServiceAudioCapture` permission through the private TCC framework, looked up with `dlsym`. |
| `PlaybackMonitor.swift` | 135 | Decides play / pause and the status text (paused, locked, asleep, battery, covered); polls every 2 s. |
| `DesktopPeek.swift` | 118 | Global and local mouse monitors; decides whether a click hit empty desktop by window-list inspection and a Finder AppleScript. |
| `ToneReporter.swift` | 73 | Turns what is on screen into a brightness function and posts readings for the clock's region. |
| `ClockHelper.swift` | 66 | Starts, restarts and stops the embedded clock app; removes the old launchd clock once. |
| `LockScreen.swift` | 73 | Sets a still frame of the video as every screen's desktop picture and restores the previous one. |
| `MovingLockScreen.swift` | 343 | Swaps the picked Aerials' video files for an HEVC 240 fps conversion (`AerialEncoder`) and restores them. |

### Sources/HimawariClock (the clock helper, 437 lines)

| File | Lines | Purpose |
|---|---|---|
| `main.swift` | 22 | `runBackgroundService`, settings and screen-change observers, parent-pid watchdog. |
| `DesktopClock.swift` | 278 | The clock window, placement, tone hysteresis, the "Clock hidden" hint, `ClockView` with its context menu, `ClockInk`. |
| `ClockFace.swift` | 137 | Text for each format, tick schedule per format, `ClockTicker` (strict dispatch timer), `FixedWidthDigits`. |

### Sources/HimawariKit (shared, 1,714 lines)

| File | Lines | Purpose |
|---|---|---|
| `Settings.swift` | 198 | Shared settings in the `local.dhairyabhatia.desktop` domain; cross-process change broadcast; clock enums. |
| `MainThread.swift` | 13 | `onMainActor`: run a closure as main-actor code after checking only `Thread.isMainThread`. |
| `NowPlaying.swift` | 716 | `MusicNowPlaying` (Music state, controls, artwork, deck), `MotionArtwork` (catalog search, HLS variant choice), `YouTubeLoop`, `YouTubeLoopView`. |
| `SystemNowPlaying.swift` | 113 | Runs the Perl-hosted MediaRemote helper and parses its JSON lines. |
| `WallpaperTone.swift` | 194 | 8×8 brightness grid, `ToneReading`, the clock ⇄ Himawari notifications, `FrameSampler`. |
| `DesktopWindow.swift` | 71 | `DesktopLayer` offsets, `DesktopWindow` (borderless desktop window), `FirstClickHostingView`, `runBackgroundService`. |
| `DesktopLayout.swift` | 62 | Reserved screen "zones" shared through settings; the clock reads them to avoid other desktop furniture. |
| `PowerState.swift` | 46 | Battery Saver = on battery or Low Power Mode; change callbacks. |
| `ScreenGeometry.swift` | 7 | `NSScreen.menuBarStripHeight` (menu bar or notch). |
| `Hotkeys.swift` | 218 | `HotKey` (Carbon global hotkeys, used); `Ghostty`, `FullScreen`, `Keys` (unused leftovers). |
| `AeroStyle.swift` | 76 | Aero font lookup (`aeroNSFont`, used by the clock) and SwiftUI Aero glass views (unused). |

### Everything else

| File | Lines | Purpose |
|---|---|---|
| `Package.swift` | 14 | The three targets, macOS 14.4. |
| `build.sh` | 81 | Release build (optionally universal), icon, bundle assembly, Info.plists, helper dylib, clock embedding, signing. |
| `install.sh` | 49 | Builds, migrates old settings, removes `Hanabi.app`, replaces and opens `/Applications/Himawari.app`. |
| `scripts/make_dmg.sh` | 81 | Universal build into a laid-out, compressed DMG with a Read Me. |
| `tools/make_icon.swift` | 96 | Script that draws the 1024×1024 sunflower icon PNG. |
| `tools/make_signing_identity.sh` | 26 | Creates the self-signed "Hanabi Local Code Signing" identity in the login keychain. |
| `helpers/NowPlayingHelper.m` | 97 | MediaRemote → JSON lines, run inside `/usr/bin/perl`. |
| `Resources/Info.plist` | 30 | Himawari's bundle keys, version 1.1.3 (5), usage descriptions. |
| `Resources/AppIcon.icns` | binary | The built icon, committed so builds don't redraw it. |
| `maintenance/weekly.sh` | 83 | Weekly launchd job: dependency updates, a Claude Code maintenance pass, build, commit, install. |
| `maintenance/prompt.md` | 24 | The instructions given to Claude Code by `weekly.sh`. |
| `README.md` | 307 | User and developer documentation, permissions, network use, AI-assistance note. |
| `ROADMAP.md` | 23 | Done features and (empty) idea list. |
| `.gitignore` | 4 | `.build/`, `build/`, `maintenance/logs/`, `.DS_Store`. |
| `docs/*.gif`, `docs/icon.png` | binary | README illustrations. |
| `docs/architecture.svg`, `docs/layers.svg` | 60, 24 | README diagrams of the data flow and the window layers. |
| `build/` (ignored) | — | Assembled apps, iconset, DMGs of past versions (`Himawari-1.0` … `1.1.3`, including an abandoned `1.2`), a stale `Hanabi.app`. |
| `maintenance/logs/` (ignored) | — | One log per bot run, plus leftovers from an older desktop-organizing job. |

Total: 6,986 lines of Swift and 97 of Objective-C.

## Windows and layers

macOS stacks windows by *level*. The desktop picture is drawn at `kCGDesktopWindowLevel`;
Finder's desktop icons live in one full-screen window at `kCGDesktopIconWindowLevel`, twenty
levels higher; ordinary app windows are at level 0, far above both. Himawari computes every level
it uses relative to `CGWindowLevelForKey(.desktopWindow)`:

| Level (desktop + n) | Window | Owner | Takes clicks? | Source |
|---|---|---|---|---|
| +0 | macOS desktop picture (what the lock screen shows) | WindowServer / Dock | — | — |
| **+1** | Wallpaper window per screen (`NSPanel`, opaque, black background) holding a `VideoCanvas`, and over it any `MusicScene` or `YouTubeLoopView` | Himawari | no (`ignoresMouseEvents = true`) | `WallpaperManager.level`, `WallpaperManager.swift:78` |
| +20 | Finder's desktop icons | Finder | yes | system |
| **+21** | The same wallpaper windows while "Hide Desktop Files" is active | Himawari | yes (a click restores the icons) | `WallpaperManager.clearLevel`, `:106` |
| **+22** | Desktop clock window (`DesktopWindow`, interactive) and its "Clock hidden" hint (not interactive) | HimawariClock | clock yes, hint no | `DesktopLayer.folders`, `DesktopClock.swift:87,102` |
| **+22** | Gear click catchers, one small `NSPanel` per control and one round one over the CD | Himawari | yes, only within the control | `GearControls.swift:226` |
| 0 and up | App windows, Dock, menu bar | others | yes | — |

`DesktopLayer` (`DesktopWindow.swift:8-17`) still names `decorations = 2` "the clock
(click-through)" and `overlay = 23` "an opened folder"; neither constant is used now. The clock
moved to +22 so it can be clicked.

All Himawari windows use the collection behaviour `[.canJoinAllSpaces, .stationary,
.ignoresCycle, .fullScreenNone]`: present on every Space, not moved by Exposé / Mission Control,
skipped by ⌘\`, not given a full-screen tile. The wallpaper and catcher panels are
`.nonactivatingPanel`, so clicking them does not make Himawari the active app or steal keyboard
focus. The catchers' content is filled with black at alpha 0.004 because the window server
passes clicks through fully transparent pixels (`GearControls.swift:249-250`).

A consequence the ROADMAP states: while the gear or the CD is visible, a desktop icon lying
exactly under a catcher cannot be clicked.

## Main data flows

### Song → wallpaper

```
 Music.app ──(1) DistributedNotification "com.apple.Music.playerInfo"──┐
     │                                                                 │
     ├──(2) MediaRemote ⇒ perl+dylib ⇒ JSON line ⇒ SystemNowPlaying ───┤
     │                                                                 ▼
     └──(3) AppleScript (NSAppleScript on scriptQueue; osascript) ⇒ MusicNowPlaying
                                                                 @Published track, isPlaying,
                                                                 artwork, motionVideo,
                                                                 youtubeVideos, searching, position
             iTunes Search API ─▶ music.apple.com album page ─▶ mvod…m3u8 ──┘ (MotionArtwork.find)
                                                                 │ Combine: CombineLatest4 + combineLatest
                                                                 ▼ .receive(on: RunLoop.main)
                                              AppDelegate.applyMusicWallpaper (pause grace, direction)
                                                                 │
          ┌──────────────────────┬─────────────────────┬─────────┴──────────┬───────────────────┐
          ▼                      ▼                     ▼                    ▼                   ▼
   setOverride(m3u8)      setYouTube(ids)        setScene(cover)       setSong(SongInfo)  monitor.evaluate()
   bestVariant → AVQueuePlayer  YouTubeLoopView   MusicScene + DiscPrint  NowPlayingSides
```

The three sources complement each other. The Music app's distributed notification arrives on
every track or state change without any permission but carries no position or artwork. The
MediaRemote stream gives an exact elapsed time with a timestamp and rate, and the exact cover
Music is showing, the moment anything changes. AppleScript (one Apple-event round trip, timed on
both sides to estimate when the position was read) fills the gaps: it is polled every 5 s only
while the MediaRemote stream has been silent for more than 12 s, and is always used for commands.

For a new track, `MusicNowPlaying.set(track:playing:)` bumps a `generation` counter, clears the
artwork (so the last song's cover is never shown for the new one), and starts the lookup: the
cover from Music (AppleScript writes the raw artwork to a temp file), and `MotionArtwork.find`,
which searches the catalog for the song (to get the exact album it is on), then for the album,
fetches the album's HTML page with a Safari user agent, and extracts the first
`https://mvod.itunes.apple.com/….m3u8` after `"motionDetailSquare"`. Results are cached in
memory per `artist|album` (or `artist|song:<title>` when Music reports no album); a result that found nothing is looked up again after 120 s, because
"nothing" may only mean the network was down (just after wake, for example). Every asynchronous completion checks that
`generation` is unchanged before applying, which is how stale results after a skip are
discarded. `WallpaperManager.setOverride` then reads the HLS master playlist itself and picks
the sharpest variant no larger than the screen (1080 in Battery Saver), preferring HEVC, because
a 20-second loop ends before AVPlayer's adaptive bitrate would ever step up.

`AppDelegate.applyMusicWallpaper` (chapter 3) decides which of the four looks is shown. In
priority order: motion artwork; else a YouTube loop if enabled and not in Battery Saver; else the
CD scene with the cover; else, when nothing is playing for more than the 3 s grace period, the
user's own video.

### Clock ⇄ tone

The clock's ink must stay readable over whatever is behind it, but the clock process cannot see
Himawari's frames and screen recording is deliberately not used. They talk through two
distributed notifications defined in `WallpaperTone.swift:72-73`:

```
 HimawariClock                                           Himawari
 ─────────────                                           ────────
 window placed / moved
   WallpaperTone.requestReading(region) ───"local.dhairyabhatia.wallpaperTone.request"──▶
     region = clock text rect as fractions of the                 onReadingRequest
     main screen, y down                                           → WallpaperManager.clockMoved
                                                                   → ToneReporter.clockMoved → publish(force)
                                                ◀──"local.dhairyabhatia.wallpaperTone.reading"──
   observeReadings → updateTone()                                  grid: 64 NSNumbers (8×8),
     dark text if focus > 0.6, light if < 0.5                      focus: mean luma behind clock,
     "busy" (more halo) if spread > 0.19, off < 0.13               spread: std-dev of luma
   (a reading without focus ⇒ Himawari doesn't know
    where the clock is ⇒ send requestReading again)
                                                  every 3 s (10 s in Battery Saver):
                                                  AVPlayerItemVideoOutput 64×64 BGRA → FrameSampler
                                                  → ToneReporter.show(…) → post only if changed
                                                  (grid cell > 0.06 or focus/spread > 0.04)
```

For the CD scene the cover image is sampled once inside the disc's rectangle; for YouTube the
video's thumbnail is fetched from `i.ytimg.com` and measured where the video sits. Without
Himawari (or before its first answer) the clock measures the macOS desktop picture with
`WallpaperTone.systemWallpaperGrid`.

Settings flow over a third notification, `local.dhairyabhatia.desktop.changed`, posted by
`HimawariKit.Settings.broadcastChange()`. Himawari posts it when the menu toggles the clock;
the clock posts it when its own context menu changes something; the clock's `Settings.onChange`
handler coalesces bursts within 0.15 s and calls `DesktopClock.refresh()`, which rebuilds the
window only if a signature of the relevant settings and free area changed.

### Clicks → Music

```
 mouse ─▶ Catcher (NSPanel at desktop+22 over one control)
            CatcherView.mouseDown / Dragged / Up  (point in the catcher's coordinates)
              │ onDown / onDrag / onUp / onDoubleClick closures built in GearControls.catcher(for:gear:)
              ▼
          gear?.press(control)  … immediate visual feedback on the drawn gear
          GearControls.perform?(Action)          Action = .button / .seek / .scrub / .volume / .tone
              ▼
          AppDelegate (closure set at launch, AppDelegate.swift:102-133)
              ▼
          MusicNowPlaying.playPause / next / previous / pause / seek / setVolume /
                         setRepeat / setShuffle / setTone / openMusic
              ▼
          osascript child: tell application id "com.apple.Music" to …   → then refresh()
```

Volume changes are throttled to ten a second while dragging; BASS / TREBLE to one every 0.25 s,
with the final value sent 0.3 s after release. While a knob is being turned, the 3-second
`deckTimer` that re-reads Music's volume, repeat, shuffle and equalizer is held off for 1.5 s so
it does not jump the knob back.

The other click path is `DesktopPeek`: a global monitor sees a left click whose down and up are
less than 5 points apart, checks with `CGWindowListCopyWindowInfo` that the frontmost window at
that point is Finder's desktop-icon window, waits 0.15 s, and asks Finder by AppleScript how many
items are selected. Zero means an empty spot was clicked, and the wallpaper rises to +21.

## Threading model

Almost everything is main-thread code. Every class that touches AppKit or holds UI state is
annotated `@MainActor` (`AppDelegate`, `WallpaperManager`, `VideoCanvas`, `MusicScene`,
`NowPlayingSides`, `GearControls`, `PlaybackMonitor`, `DesktopPeek`, `ToneReporter`,
`ClockHelper`, `MovingLockScreen`, `MusicNowPlaying`, `HotKey`, `Log`, `DesktopClock`,
`ClockTicker`, and the enums `LockScreen`, `PowerState`, `DesktopLayout`).

Callbacks that AppKit or Foundation deliver on the main thread but which Swift does not know are
main-actor (timer blocks, `NotificationCenter` observers with `queue: .main`, event monitors) are
wrapped in `onMainActor { … }` from `MainThread.swift`. It checks `Thread.isMainThread` and then
calls the closure as if it were main-actor isolated. It exists because the Swift runtime's own
executor check crashed Himawari from plain main-thread timers (chapter 3 explains). Callbacks
that arrive on other threads are first hopped with `DispatchQueue.main.async { onMainActor { … } }`.

Work that leaves the main thread:

| Work | Where it runs | How results come back |
|---|---|---|
| `osascript` children for Music commands, artwork export, volume | `DispatchQueue.global(qos: .utility)` (`NowPlaying.swift:373`) | `DispatchQueue.main.async` + `onMainActor` |
| In-process `NSAppleScript` for state and deck reads | serial `local.dhairyabhatia.nowplaying.script`, `.userInitiated`; compiled scripts cached in a dictionary touched only there | same |
| Finder selection check | `DispatchQueue.global(qos: .userInitiated)` (`DesktopPeek.swift:97`) | same |
| MediaRemote JSON | pipe `readabilityHandler` (Foundation's I/O thread) → serial `local.dhairyabhatia.nowplaying.system` for line splitting and parsing | `DispatchQueue.main.async` |
| Audio tap analysis (RMS, FFT via Accelerate) | Core Audio I/O block on serial `local.dhairyabhatia.himawari.levels`, `.userInteractive` | `OSAllocatedUnfairLock`-protected `Snapshot`, read by the gear's 30 Hz main-thread timer |
| Scratch sound synthesis | `AVAudioSourceNode` render block on the real-time audio thread | none (writes audio buffers); `speed` set unsynchronized from main |
| Disc print rendering | `DispatchQueue.global(qos: .userInitiated)` (`MusicScene.swift:376`) | main, newest job wins |
| Network (catalog, album pages, playlists, covers, thumbnails) | `URLSession` awaited inside `Task`s started from main-actor code | the `Task` resumes on the main actor |
| Aerial conversion (`AerialEncoder.encode`) | a nonisolated `async` static function called from a main-actor `Task`, so it runs on the global concurrent executor | progress via `Task { @MainActor in … }` |
| Video decoding, Core Animation | AVFoundation and the window server | KVO hopped to main |
| Clock ticks | `DispatchSourceTimer` on the main queue, `.strict`, 2 ms leeway | — |

Shared mutable state across threads is small and explicitly guarded: the audio `Snapshot` and
`lastHeard` behind unfair locks, `SystemNowPlaying.pending` touched only on its queue, and a few
`@unchecked Sendable` boxes that carry main-actor closures across queues.

## Persistence

### Preferences domains

| Domain | Opened by | Keys |
|---|---|---|
| `local.dhairyabhatia.himawari` (Himawari's `UserDefaults.standard`) | `Himawari.Settings`, `LockScreen`, `MovingLockScreen`, `AppDelegate.setTone` | `videoPath`, `volume`, `muted`, `pauseOnBattery`, `pauseWhenCovered`, `userPaused`, `showInDock`, `musicWallpaper`, `musicYouTube`, `clickToClearDesktop`, `lockScreenMatch`, `movingLockScreen`, `videoSizing`, `barFill` (and legacy `blurredBars`, read only), `lockScreenOriginalWallpapers` (screen name → picture path), `movingLockScreenState` (`{video, applied: {assetID: bytes}}`), `toneRestoreOn`, `toneRestorePreset`; plus AppKit's own (open-panel state) |
| `local.dhairyabhatia.desktop` (suite, both processes) | `HimawariKit.Settings` | `showClock`, `clockPosition`, `clock24h`, `clockFormat`, `clockShowDate`, `clockSize`, `clockStyle`, `clockSeconds`; `zone.widgets` / `zone.folders` / `zone.taskbar` (read by the clock through `DesktopLayout`); `migrated` (written by `install.sh`). The kit also defines wallpaper keys (`videoPath`, `volume`, …) here that nothing in this repository reads. Other "Desktop Shell" programs may write further keys into the same domain. |
| `local.dhairyabhatia.desktop.clock` | the clock's own `UserDefaults.standard` | nothing written by the code |
| `local.dhairyabhatia.hanabi` | read once by `install.sh` | copied into `…himawari` if that domain is empty |

### Files

| Path | Written by | Contents |
|---|---|---|
| `~/Library/Logs/Himawari.log` | `Log.write` | timestamped lines; older half dropped past 1 MB |
| `~/Library/Application Support/Himawari/Lock Screen/Himawari-<unix time>.png` | `LockScreen.show` | the still frame; a new name each time because macOS caches desktop pictures by path |
| `~/Library/Application Support/Himawari/Moving Lock Screen.mov` | `AerialEncoder` | the 3840×2160 HEVC 240 fps master |
| `~/Library/Application Support/Himawari/Moving Lock Screen.partial.mov` | `AerialEncoder` | the conversion in progress; moved over the master only when complete, deleted on failure or cancel |
| `~/Library/Application Support/Himawari/<assetID>.trim.mov` | `MovingLockScreen.swap` | temporary passthrough trim, moved into place |
| `~/Library/Application Support/Himawari/Aerial Originals/<assetID>.mov` | `MovingLockScreen.swap` | Apple's original Aerial videos |
| `~/Library/Application Support/com.apple.wallpaper/aerials/videos/<assetID>.mov` | `MovingLockScreen` (replaced) | macOS's Aerial video files; `…/Store/Index.plist` is only read |
| `$TMPDIR/now-playing-<pid>.img` | AppleScript in `MusicNowPlaying.loadArtwork` | the current cover as exported by Music |
| desktop picture setting per screen | `NSWorkspace.setDesktopImageURL` | changed by `LockScreen` |
| `~/Library/LaunchAgents/local.dhairyabhatia.desktop.clock.plist`, `~/Library/Application Support/Desktop Shell/Desktop Clock.app` | deleted once by `ClockHelper.retireOldService` | legacy |
| Music's equalizer preset "Himawari" | `MusicNowPlaying.setTone` | created inside Music's library |

Nothing else is cached on disk: motion-artwork and YouTube lookups are cached, with the time of
the lookup, in static dictionaries in memory only. The clock writes its "behind clock" diagnostics with `print` to its
stdout, which it inherits from Himawari (normally not captured anywhere).

## External services

| Endpoint | When | What for | Code |
|---|---|---|---|
| `https://itunes.apple.com/search` (entity `song`, then `album`; local store, then US) | each new song not in the in-memory cache | find the album the song is on | `MotionArtwork.songAlbum`, `find` |
| `https://music.apple.com/…` album pages (`collectionViewUrl`) | after a catalog hit | scrape the motion-artwork HLS address | `MotionArtwork.motion` |
| `https://mvod.itunes.apple.com/….m3u8` and its variants | while showing motion artwork | the looping cover video | `bestVariant`, AVPlayer |
| `https://*.mzstatic.com/…/1200x1200bb.jpg`, `…600x600bb` | new song | a sharper copy of the exact cover; a catalog cover if Music has none | `useSystemArtwork`, `fetchImage` |
| `https://www.youtube.com/results?search_query=…` | only with the YouTube option on and no motion artwork | find up to four candidate video ids from `ytInitialData` | `YouTubeLoop.findVideos` |
| `https://www.youtube.com/iframe_api` and the embedded player | same | play the video muted, synced to the song | `YouTubeLoopView` (WKWebView, base URL `https://localhost/`) |
| `https://i.ytimg.com/vi/<id>/mqdefault.jpg` | when a YouTube loop appears | measure brightness for the clock | `ToneReporter.showYouTube` |

Local services contacted: the Music app (distributed notifications, AppleScript, Core Audio
tap), Finder (AppleScript), the private MediaRemote framework (inside Perl), the private TCC
framework (permission preflight / request), WindowServer window lists, IOKit power sources,
`launchctl`, System Settings (by `x-apple.systempreferences:` URL when Moving Lock Screen needs an
Aerial picked), and `SMAppService` for the login item. The macOS permissions involved are
Automation for Music and for Finder, and "System Audio Recording Only"; window positions need no
Screen Recording permission because titles are never read.

### Notes and risks

- `Sources/HimawariKit/Settings.swift:16-17`: the comment says the wallpaper app's own domain is
  the shared one, but Himawari's bundle id is `local.dhairyabhatia.himawari`, so both processes
  open `local.dhairyabhatia.desktop` as a suite; the comment is stale.
- `Sources/HimawariKit/DesktopWindow.swift:10,12`: `DesktopLayer.decorations` and `overlay` are
  unused, and the comment on `decorations` (clock, click-through) no longer matches the clock at
  +22, interactive.
- `Sources/HimawariKit/Hotkeys.swift:49-218` and `AeroStyle.swift:28-76`, `DesktopLayout.swift:19-25,58-61`:
  dead code carried over from Desktop Shell (Ghostty launcher, full-screen detection, key
  posting, Aero views, zone publishing). It compiles into both binaries.
- `Sources/Himawari/DesktopPeek.swift:82-84`: windows are skipped as "ours" when the owner name
  starts with "Himawari", but the clock's process is named "Desktop Clock", so a click on the
  clock counts as a non-desktop click (harmless, but the comment describes behaviour that does
  not happen).
- `Sources/Himawari/DesktopPeek.swift:30`: the local monitor now skips every `NSPanel`, which
  includes the wallpaper windows themselves (`WallpaperManager.swift:557`), so its
  `onWallpaperClick` path is dead; the canvas's own `mouseDown` still restores the files.
- `Sources/HimawariKit/DesktopLayout.swift:32-38`: the clock's free area depends on `zone.*` keys
  that only external Desktop Shell programs write; stale zones left by those programs would
  shift the clock.
- `build.sh:66-67`: the MediaRemote helper is code placed in `Contents/Resources`, which Apple's
  bundle rules reserve for non-code; it is signed separately and works locally, but the whole
  approach depends on `/usr/bin/perl` continuing to load third-party dylibs.
- The motion-artwork and YouTube paths scrape undocumented HTML/JSON (`NowPlaying.swift:552-561`,
  `:583-585`); a page change silently disables them (by design they fall back to the CD).
