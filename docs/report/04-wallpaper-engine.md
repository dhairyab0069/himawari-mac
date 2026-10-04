# 4 · The wallpaper engine

This chapter covers the part of Himawari that actually puts moving pictures on the desktop.
Nine files make up the engine. Five live in the app target (`Sources/Himawari`) and four in the
shared library (`Sources/HimawariKit`), which the desktop clock helper also links against.

| File | Lines | Role |
|---|---:|---|
| `Sources/Himawari/WallpaperManager.swift` | 574 | Owns the single `AVQueuePlayer`, one window per screen, and the choice of what is shown (your video, Apple Music motion artwork, the CD scene, a YouTube loop). |
| `Sources/Himawari/VideoCanvas.swift` | 156 | One screen's content view: lays out the video layer, the bars, the blurred backdrop and the side gear. |
| `Sources/Himawari/AmbientFill.swift` | 161 | The "Soft Colors" bar fill: a palette taken from the video's edges and a slowly drifting Core Animation layer. |
| `Sources/Himawari/PlaybackMonitor.swift` | 135 | Decides every 2 s whether the wallpaper should play, and whether anyone can see the desktop. |
| `Sources/Himawari/DesktopPeek.swift` | 112 | Click-to-hide desktop files: global and local event monitors plus a Finder selection check. |
| `Sources/HimawariKit/PowerState.swift` | 46 | "Battery Saver": on battery or in Low Power Mode, with change notifications. |
| `Sources/HimawariKit/DesktopWindow.swift` | 71 | Desktop window-level constants, a reusable borderless desktop window, and the background-service bootstrap. |
| `Sources/HimawariKit/ScreenGeometry.swift` | 7 | `NSScreen.menuBarStripHeight`: the strip under the menu bar / notch that the video avoids. |
| `Sources/HimawariKit/DesktopLayout.swift` | 62 | Shared tiling map of reserved screen strips (used by the clock to find free space). |

## Overview: how the pieces fit

`AppDelegate` (chapter on app wiring) creates exactly one `WallpaperManager`, one
`PlaybackMonitor` and one `DesktopPeek` as stored properties
(`Sources/Himawari/AppDelegate.swift:13-15`). Everything in this chapter runs on the main
thread; the only off-main work is AVFoundation's own decoding, an `osascript` child process in
`DesktopPeek`, and the audio tap inside `AudioLevels` (covered in its own chapter).

```
             Music state (MusicNowPlaying, Combine)            PowerState.onChange
                         │                                           │
                         ▼                                           ▼
   AppDelegate.applyMusicWallpaper ──► setOverride / setYouTube / setScene / setSong
                                                   │                  powerChanged()
   PlaybackMonitor (2 s timer, lock/sleep) ──► setDesktopVisible, setPlaying
   DesktopPeek (mouse monitors, Finder) ─────► setClear
   menu actions ─────────────────────────────► load, sizing, barFill, setVolume
                                                   │
                                          ┌────────▼─────────┐
                                          │ WallpaperManager │── one AVQueuePlayer
                                          └────────┬─────────┘
                       one NSPanel per NSScreen    │
         ┌─────────────────────────────────────────┼──────────────────────────┐
         ▼                                         ▼                          ▼
   VideoCanvas (contentView)            MusicScene (subview, CD)     YouTubeLoopView (subview)
     ├ backdrop AVPlayerLayer (blur)
     ├ AmbientLayer (soft colors)
     ├ band ─ video AVPlayerLayer
     └ NowPlayingSides (side gear)
                                                   │
                         ToneReporter ──► WallpaperTone.post (distributed notification) ──► clock
                         GearControls ──► click-catcher windows over gear and disc
```

### What the wallpaper shows, and when

The four "scenes" are mutually exclusive in practice. `AppDelegate.applyMusicWallpaper`
(`Sources/Himawari/AppDelegate.swift:167-215`) decides which to request; `WallpaperManager`
enforces the visual result. The diagram below is the combined state machine. "Music on" means
the Music Wallpaper setting is on and Music is playing, or paused for less than the 3-second
grace period that hides song skips.

```
                         ┌───────────────────────────────┐
           launch ─────► │ YOUR VIDEO  (override == nil, │ ◄───────────────────────────┐
                         │ youtube == nil, sceneArt nil) │                             │
                         │ sizing forced to .fill        │                             │
                         └──┬──────────────┬─────────────┘                             │
     music on & motion art  │              │ music on, no motion art                   │
     found (setOverride)    │              │                                           │
                            ▼              ├──── YouTube allowed & ids & !Battery Saver │
         ┌──────────────────────────┐      │              ▼                            │
         │ MOTION COVER (streamed   │      │   ┌────────────────────────┐              │
         │ HLS loop, override set)  │      │   │ YOUTUBE LOOP over all  │              │
         │ sizing = Video Sizing,   │      │   │ screens; player paused │              │
         │ side gear in the bars    │      │   └───────────┬────────────┘              │
         └───┬───────────┬──────────┘      │ otherwise     │ music off                 │
             │           │                 ▼               └───────────────────────────┤
             │           │     ┌────────────────────────────┐                          │
             │  next song│     │ CD SCENE (MusicScene over  │  same song, sharper art: │
             │  has none └────►│ every canvas; player       │  repaint in place        │
             │                 │ paused; disc + side gear)  │  new song: change discs  │
             │ ◄───────────────┤ (leaves only once the next │  (direction fwd/back)    │
             │  next song has  │ video has frames up)       │                          │
             │  motion art     └─────────────┬──────────────┘                          │
             │                               │ music off                               │
             └───────────────────────────────┴─────────────────────────────────────────┘

  Orthogonal to all of the above:
    playing / paused       ← PlaybackMonitor (user, lock, display sleep, battery, covered)
    files hidden / shown   ← DesktopPeek, ⌃⌥⌘D, menu  (window level +1 or +21)
    Battery Saver          ← PowerState (fills, stream size, timers, no YouTube)
```

While the next song is still being looked up (`music.searching`), `applyMusicWallpaper`
returns early if music is already on screen (`AppDelegate.swift:191-194`), so between songs
the last motion cover or CD stays rather than flashing back to your own video.

---

## Sources/Himawari/WallpaperManager.swift

**Purpose.** The engine's centre. It owns the AVFoundation player, creates and recreates the
desktop windows, and holds the state that decides which of the four scenes is visible. It is the
only object that touches the player; every other part of the app talks to it through a small
set of methods.

**Where it sits.** Created once by `AppDelegate` (`AppDelegate.swift:13`) and lives as long as
the app. Callers: `AppDelegate` for everything (load, music overrides, playback decision,
volume, menu settings, clear/unclear); the desktop clock indirectly through
`WallpaperTone.onReadingRequest` → `clockMoved(to:)` (`AppDelegate.swift:145`).

**What it calls.** `VideoCanvas`, `MusicScene`, `YouTubeLoopView`, `NowPlayingSides` (via the
canvas and scene), `GearControls`, `ToneReporter`, `AudioLevels`, `FrameSampler`,
`AmbientPalette`, `MotionArtwork.bestVariant`, `PowerState`, `Settings`, `Log`.

**Design decisions.**

- *One player for all screens.* The class comment (`WallpaperManager.swift:5-9`) states the
  core decision: every screen's `VideoCanvas` holds an `AVPlayerLayer` attached to the same
  `AVQueuePlayer`, so the video is decoded once whatever the number of monitors. The
  alternative, one player per screen, would multiply decode cost and could drift out of sync.
- *A queue player plus `AVPlayerLooper` for local files*, because the looper gives gapless
  loops by pre-queuing copies of the item. Streams use a plain item and seek back to zero
  (see `start`).
- *Panels, not windows.* Each screen gets a non-activating `NSPanel` so that clicking the
  wallpaper while files are hidden never steals focus from the frontmost app.
- *State as optionals.* What is showing is not an enum but four optionals (`chosen`,
  `override`, `youtube`, `sceneArt`). The precedence is implicit: YouTube and the scene are
  views laid on top of the canvas, the override replaces the player's item. This keeps each
  setter independent (AppDelegate calls all three in sequence) at the price of the state
  machine being spread over several `guard`s.

### `WallpaperManager` (class, `@MainActor`, `final`)

**Responsibility.** Everything visible on the desktop below the clock and the folder dock.

**Lifecycle.** Built in `AppDelegate`'s property initialiser; never torn down. Its
notification observer (`init`) and timers are therefore never removed, which is fine for an
app-lifetime singleton.

**Threading.** The class is `@MainActor`. Callbacks that AppKit or Foundation deliver on the
main queue (timers, notification blocks, KVO hops) re-enter main-actor code with
`onMainActor { … }`, a project helper (`Sources/HimawariKit/MainThread.swift:8-13`) that
checks `Thread.isMainThread` and then calls the closure as if isolated. Its comment says it
replaced Swift's own executor check because that crashed from plain timers. Timer callbacks in
this file use `Task { @MainActor … }` instead, which hops through the concurrency runtime.

**Stored state.**

| Property | Type | Meaning |
|---|---|---|
| `player` | `AVQueuePlayer` (let) | The single player shared by every screen. |
| `looper` | `AVPlayerLooper?` | Present while a local file loops. |
| `endObserver` | `NSObjectProtocol?` | `AVPlayerItemDidPlayToEndTime` observer for a streamed item. |
| `troubleObservers` | `[NSObjectProtocol]` | Failure / stall observers for a streamed item. |
| `starts` | `Int` | Counter bumped on every `start(_:)`; async work only applies if it still matches. |
| `current` | `URL?` | The URL actually loaded in the player now (may be a chosen HLS variant). |
| `watchdog` | `Timer?` | The 2 s repair timer, created on first `start`. |
| `output` | `AVPlayerItemVideoOutput?` | 64×64 BGRA frame tap used for brightness and palette. |
| `outputItem` | `AVPlayerItem?` | The item `output` is attached to (the looper swaps items). |
| `tone` | `ToneReporter` (let) | Turns what's on screen into readings for the clock. |
| `gearControls` | `GearControls` (let, internal) | Invisible click-catcher windows over the gear and disc. |
| `sceneArt` | `NSImage?` | Cover art when the CD scene is showing; nil otherwise. |
| `scenes` | `[MusicScene]` | One CD scene view per window while the scene shows. |
| `sceneSong` | `String?` | `"title|artist"` of the song whose cover is on the disc. |
| `discDirection` | `DiscDirection` (internal) | `.forward` / `.backward`: which way the next disc change slides. Set by AppDelegate. |
| `song` | `SongInfo?` | Current song for the side gear. |
| `audio` | `AudioLevels` (let) | The system-audio tap feeding the VU meters. |
| `levelsStop` | `DispatchWorkItem?` | Pending delayed stop of the audio tap. |
| `audioHeard` | `Bool` | Last value of `audio.hearing` seen by `checkHearing`. |
| `desktopVisible` | `Bool` | Whether the desktop can be seen (from `PlaybackMonitor`). |
| `toneTimer` | `Timer?` | The 3 s (10 s in Battery Saver) brightness sampler. |
| `windows` | `[NSWindow]` | One panel per screen. |
| `cleared` | `Bool` (private(set)) | Desktop files hidden (wallpaper raised above Finder's icons). |
| `onClearedClick` | `(() -> Void)?` | Called when a canvas is clicked (only possible while cleared). |
| `chosen` | `URL?` | Your wallpaper video. |
| `override` | `URL?` | Apple Music motion artwork master playlist URL, while a song plays. |
| `youtube` | `[String]?` | YouTube video ids for the loop, when there's no motion artwork. |
| `youtubeViews` | `[YouTubeLoopView]` | One web player view per window. |
| `canvases` | `[VideoCanvas]` | One per window; each window's `contentView`. |
| `sizeWatch` | `NSKeyValueObservation?` | KVO on `player.currentItem?.presentationSize`. |
| `playing` | `Bool` | The playback decision from `PlaybackMonitor`. |
| `barFill` | `BarFill` (internal) | What fills the bars; `didSet` calls `applyBarFill()`. |
| `sizing` | `VideoSizing` (internal) | Video Sizing menu choice; `didSet` re-lays out canvases and YouTube. |

Two static constants define the window levels (`level`, `clearLevel`), discussed next.

### Window levels and the per-screen windows

macOS stacks windows by *level*, an integer. `CGWindowLevelForKey` returns the level for named
system layers. `.desktopWindow` is where macOS draws the wallpaper picture; `.desktopIconWindow`
is where Finder draws the desktop icons, 20 levels higher (the comment in
`Sources/HimawariKit/DesktopWindow.swift:4-7` describes this layout). Normal app windows are
far above both (level 0; the desktop levels are large negative numbers).

```swift
/// Above the picture macOS draws as wallpaper, below Finder's desktop icons.
private static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
```
(`WallpaperManager.swift:76-77`)

```swift
/// Just above Finder's desktop icons: covers them.
private static let clearLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
```
(`WallpaperManager.swift:104-105`)

The resulting stack, bottom to top:

| Level (relative to `.desktopWindow`) | What |
|---:|---|
| +0 | macOS wallpaper picture |
| **+1** | **Himawari wallpaper (normal)** — `level`, also `DesktopLayer.video` |
| +2 | `DesktopLayer.decorations` (declared, unused in this repo) |
| +20 | Finder's desktop icons (`.desktopIconWindow`) |
| **+21** | **Himawari wallpaper (files hidden)** — `clearLevel` |
| +22 | `DesktopLayer.folders`: desktop clock, `GearControls` catchers |
| +23 | `DesktopLayer.overlay` (declared, unused in this repo) |

Note that `WallpaperManager` computes its levels directly rather than through
`DesktopLayer.level(_:)`; the values agree (`DesktopLayer.video == 1`).

#### `makeWindow(for:)` (`WallpaperManager.swift:544-573`)

Input: an `NSScreen`. Output: a configured, ordered-front window. Steps:

1. Creates an `NSPanel` with `[.borderless, .nonactivatingPanel]` covering `screen.frame`.
   A non-activating panel can receive clicks without making Himawari the active app.
   `hidesOnDeactivate = false` because panels hide on deactivation by default.
2. Sets the level to `clearLevel` or `level` depending on `cleared` (so a rebuild while files
   are hidden keeps them hidden).
3. `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]`:
   present on every Space, not moved by Mission Control/Exposé, skipped by ⌘\` window cycling,
   and never made full-screen.
4. `ignoresMouseEvents = !cleared`: normally clicks pass through to Finder.
5. Opaque, black background, no shadow, `isReleasedWhenClosed = false` (the array owns it).
6. Builds a `VideoCanvas(player:scale:)` with the screen's `backingScaleFactor`, sets its
   frame, sizing (`effectiveSizing`), click handler (forwards to `onClearedClick`), bar fill
   (blurred demoted to ambient in Battery Saver), `ambientMotion`, `sidesLively`, `topInset`
   (`screen.menuBarStripHeight`) and the current `videoSize`, and installs it as the
   `contentView`.
7. Appends the canvas to `canvases` and calls `orderFrontRegardless()`, which shows a window
   without activating the app.

#### `rebuildWindows()` (`WallpaperManager.swift:533-542`)

Called from `init` and on every `NSApplication.didChangeScreenParametersNotification` (a
monitor plugged or unplugged, resolution or arrangement changed). It orders out the old
windows, empties `youtubeViews`, `canvases` and `scenes`, builds one window per
`NSScreen.screens`, then re-adds a YouTube view and a CD scene to each (both functions are
no-ops when that scene isn't active), and finally calls `applySong()` so the side gear is
recreated. The old windows are released when the array is replaced. Old scenes are dropped
without their `leave` animation, and new ones play `arrive` again, so a display change
replays the disc's entrance.

#### `setClear(_:)` (`WallpaperManager.swift:107-116`)

Hides (true) or restores (false) the desktop files. It is guarded against no-op calls, then for
every window swaps the level between `clearLevel` and `level`, flips `ignoresMouseEvents` (the
raised wallpaper must take clicks so a click can bring the files back), and re-orders the
window front within its level. Finder's icons are not hidden at all; they are simply covered.
Callers: `DesktopPeek.onChange`, `onClearedClick` and `peek.onWallpaperClick` (all wired in
`AppDelegate.swift:80-82`), the ⌃⌥⌘D hot key and the menu item (`AppDelegate.swift:511`), and
turning the feature off (`AppDelegate.swift:566`).

### `init()` (`WallpaperManager.swift:79-99`)

1. `player.preventsDisplaySleepDuringVideoPlayback = false`. AVPlayer holds a display-sleep
   assertion while playing video by default; a wallpaper that kept the screen awake would be a
   serious battery bug.
2. `audio.onPermission` re-runs `applySong()` once the user grants audio-capture permission, so
   the meters go live without waiting for the next song change.
3. Observes screen-parameter changes on the main queue and rebuilds the windows.
4. Installs KVO on `\.currentItem?.presentationSize` with `.initial, .new`. The presentation
   size is the video's display size in pixels (zero until the item has loaded). The change
   handler can run on any thread, so it hops to the main queue before writing
   `videoSize` into every canvas. This is what lets sizing be exact per video.
5. `rebuildWindows()`.

### Loading and the `start(_:)` pipeline

#### `load(url:)` and `hasVideo`

`load(url:)` (`:118-121`) stores the chosen video and only starts it if no motion artwork is
overriding it; the override's return path (`setOverride(nil)`) starts `chosen` later.
`hasVideo` (`:101`) is true when either a chosen video or an override exists; AppDelegate uses
it for the menu-bar icon and to show the file picker at first launch.

#### `start(_:)` (`WallpaperManager.swift:157-212`)

The single entry point that puts a URL into the player. It handles two very different kinds
of media.

**Common preamble.** It records whether the player was playing (`rate > 0 || playing`), sets
`current`, bumps `starts` and captures it in a local `start`, disables and drops the looper,
removes all queued items, and removes the stream observers from any previous start.

**The `starts` guard.**

```swift
// Only the newest start may take over the player: two loopers on one player crash
// (AVPlayerLooper throws when its items are already queued elsewhere).
starts += 1
let start = starts
```
(`WallpaperManager.swift:160-163`)

`start` can be called again before an earlier call's asynchronous work has finished (for
example toggling mute twice quickly, or the watchdog re-starting). Only the muted path does
asynchronous work, and its continuation checks `self.starts == start` before touching the
player. Without it, two continuations could each build an `AVPlayerLooper` on the same player,
which the comment reports as a crash. It is a generation counter rather than task
cancellation: the stale `pictureOnly` work still runs to completion, it just discards its
result.

**Local files: looping.** `actionAtItemEnd = .advance` lets the queue move to the looper's next
copy. `AVPlayerLooper(player:templateItem:)` keeps a queue player supplied with copies of the
template item laid end to end, giving a gap-free loop; `disableLooping()` stops it.

- *Muted (the default; `Settings` registers `muted: true`).* A `Task` (inheriting main-actor
  isolation) awaits `pictureOnly(url)`; if this is still the newest start it clears the queue
  again, builds the looper with the silent item (or the original if stripping wasn't possible),
  and resumes playback if `playing`.

```swift
Task { [weak self] in
    let silent = await Self.pictureOnly(url)
    guard let self, self.starts == start else { return }
    self.player.removeAllItems()
    self.looper = AVPlayerLooper(player: self.player, templateItem: silent ?? AVPlayerItem(url: url))
    if self.playing { self.player.play() }
}
```
(`WallpaperManager.swift:176-182`)

- *Not muted.* The looper is built synchronously from `AVPlayerItem(url:)`.

**Streams: Apple Music motion artwork.** The motion artwork is an HLS stream (a playlist of
short segments). `AVPlayerLooper` is not used. Instead:

- `actionAtItemEnd = .none`: a queue player with `.advance` would drop the finished item and
  show black; `.none` keeps it parked on its last frame.
- `preferredForwardBufferDuration = 30`: the loops are about 20 s, so the whole loop is
  buffered and later passes don't touch the network.
- `preferredPeakBitRate = 0`: no bitrate cap.
- An `AVPlayerItemDidPlayToEndTime` observer seeks to `.zero` and plays again. The closure
  captures the player weakly.
- `AVPlayerItemFailedToPlayToEndTime` and `AVPlayerItemPlaybackStalled` observers schedule a
  full `start(url)` one second later, but only if `current` is still that URL.

**Common tail.** If the player was playing and neither YouTube nor the CD scene is covering it,
`play()`. Then `sampleSoon()` (measure the new picture quickly), `startWatchdog()` and
`startToneSampling()` (both idempotent).

#### `pictureOnly(_:)` (`WallpaperManager.swift:520-531`)

A static async function that returns an `AVPlayerItem` containing only the video track, or nil.
It loads the asset's video track, duration and audio tracks with the modern async `load` APIs;
if there is no audio track there is nothing to strip, so it returns nil (and `start` falls back
to the plain item). Otherwise it builds an `AVMutableComposition`, a lightweight editing
timeline that references the source media without copying it, adds one video track, inserts
the full time range of the source video track, copies the `preferredTransform` (the rotation
metadata that phone videos rely on), and wraps the composition in a player item. Effect: the
audio track is never decoded. The cost is the asynchronous load before playback starts.

#### `setVolume(_:muted:)` (`WallpaperManager.swift:509-518`)

Treats volume below 0.005 as muted, applies volume and mute to the player, and, if the muted
state changed while a local file is on screen and no scene or YouTube covers it, calls
`start(current)` to switch between the picture-only and with-sound items. Streams are not
restarted (the motion artwork is silent).

### Motion artwork: `setOverride(_:)` (`WallpaperManager.swift:134-155`)

Input: the master HLS URL of the album's motion artwork, or nil to return to your video.

1. Guard against no change; store `override`; `applySong()` (the side gear appears only on the
   motion cover).
2. *nil:* start `chosen` first, *then* switch canvases back to `.fill`. The comment explains the
   order: the other way round, the square animation would flash stretched to fill the screen.
3. *URL:* switch canvases to the Video Sizing mode, compute the largest screen's longest side
   in pixels (`max(width, height) * backingScaleFactor`, default 2560), cap it at 1080 in
   Battery Saver, and in a `Task` ask `MotionArtwork.bestVariant(of:maxSide:)` for the
   sharpest variant stream that fits.
4. When the answer arrives, it only starts it if `override` is still that URL (a newer song may
   have replaced it meanwhile). This is the stream path's equivalent of the `starts` guard.

`bestVariant` (in `Sources/HimawariKit/NowPlaying.swift:424-443`) downloads the master
playlist, parses each `#EXT-X-STREAM-INF` line for `RESOLUTION` and `BANDWIDTH` and whether the
codec is `hvc1` (HEVC), keeps variants whose longest side is at most 115 % of `maxSide`, and
picks the largest, preferring HEVC and then bandwidth. If nothing fits it takes the smallest;
on any failure it returns the master URL. The reason (`NowPlaying.swift:421-423`): HLS players
start at a low variant and a 20-second loop ends before adaptive bitrate would step up, so the
picture would stay blurry.

### Sizing and bar fills

`sizing` (`:69-74`) holds the user's Video Sizing choice. Its `didSet` pushes
`effectiveSizing` to every canvas and, if a YouTube loop is showing, tears it down and re-adds
it (by setting `youtube = nil` then calling `setYouTube` with the same ids) because the YouTube
view's frame depends on the mode.

`effectiveSizing` (`:67`) is `sizing` only while an override (motion artwork) is set, and
`.fill` otherwise: "Your own wallpaper always fills the screen; Video Sizing … is for the music
wallpaper." The YouTube layout uses `sizing` directly, which is consistent because YouTube
only appears for music.

`barFill` (`:58`) holds the bar-fill choice; `applyBarFill()` (`:61-64`) pushes it to every
canvas, demoting `.blurred` to `.ambient` in Battery Saver (blurring live video every frame is
the most expensive fill) and turning off the ambient drift animation in Battery Saver.

`powerChanged()` (`:123-132`) is the `PowerState.onChange` handler (`AppDelegate.swift:89-92`):
re-applies the bar fill, sets `lively` on scenes and `sidesLively` on canvases, recreates the
tone timer with the new interval, and re-resolves the motion artwork stream (clearing
`override` and calling `setOverride` again so the 1080-pixel cap is applied or lifted).

### The CD scene and disc-changer transitions

When a song has neither motion artwork nor (allowed) YouTube video, AppDelegate asks for the
CD scene with the song's cover. `MusicScene` (its own chapter) draws a spinning disc printed
with the cover, a backdrop in the cover's colours and the side gear.

#### `setScene(_:)` (`WallpaperManager.swift:276-307`)

Input: the cover `NSImage`, or nil to remove the scene. Identity comparison (`!==`) is used
because a sharper copy of the same cover is a different object and should be applied.

*Already showing a CD, new art.* It compares the current song's `"title|artist"` key with
`sceneSong`. Same song: `repaint(with:)` reprints the disc in place (a higher-resolution cover
arrived). Different song: `setArtwork(_:direction:)` performs the disc-changer transition in
the direction set by AppDelegate's `noteDirection()`: forward slides the old disc out left and
the new one in from the right; Previous does the reverse. Then `sceneTone()` and return.

```swift
let sameSong = song.map { "\($0.title)|\($0.artist)" } == sceneSong
sceneArt = art
scenes.forEach { sameSong ? $0.repaint(with: art) : $0.setArtwork(art, direction: discDirection) }
sceneSong = song.map { "\($0.title)|\($0.artist)" }
```
(`WallpaperManager.swift:282-285`)

This relies on AppDelegate calling `updateSong()` *before* `setScene`
(`AppDelegate.swift:199`, commented "before the scene, which tells a new song's cover from a
sharper copy by it").

*Otherwise (scene appearing, disappearing, or replacing).* It records `sceneSong` and
`sceneArt`, moves the existing scene views into a local `leaving` array, and empties `scenes`.
The leaving scenes play `MusicScene.leave` (disc slides off left, shrinking, then the view
fades) and remove themselves, but only once `whenVideoShows` reports that what comes next is
on screen. Then `applySong()`. If there is new art: add a scene to every window (`addScene`),
pause the player (it's hidden), and measure the scene for the clock. If nil: resume the player
if playing and YouTube isn't up, clear the tone reading and schedule quick samples.

#### `whenVideoShows(_:)` and `videoShows` (`:309-327`)

`whenVideoShows` polls `videoShows` every 100 ms up to 40 times (4 s), then runs the closure
regardless. `videoShows` is true when a YouTube loop is up (it covers everything), or when the
player's item is `.readyToPlay` with a non-zero presentation size *and* it is the right video:
either no override is set, or `current` has moved off `chosen` (meaning the motion artwork
stream has replaced your video). The effect: when leaving the CD for a song with motion
artwork, the disc stays until the animation has frames, instead of revealing your paused
video for a moment.

#### `addScene(to:)` (`:352-363`)

Needs `sceneArt`, the window's content view and screen. Insets the scene by the menu-bar strip
on top and by the Dock on the bottom (`visibleFrame.minY - frame.minY`), sets autoresizing,
`running` (animate only while the desktop is visible), `lively` (not in Battery Saver), adds it
as a subview of the canvas, appends it to `scenes`, and calls `arrive(from:)`: the scene fades
in over 0.35 s while the disc slides in from the side matching `discDirection`.

#### `sceneTone()` (`:365-372`)

Reports the scene's brightness to the clock once. It takes the scene on the main screen (or
the first), samples the cover into a 64×64 `FrameSampler`, converts the scene's `discRect`
(AppKit view coordinates, y up) into screen fractions with y down, and calls `tone.show` with
the cover drawn at the disc's rect and the rest of the screen at the scene palette's luma,
with `force: true` so the clock updates even if the reading is similar.

### YouTube loops

`setYouTube(_:)` (`:458-475`) normalises an empty array to nil, guards no-ops, removes all
existing YouTube views, and calls `applySong()` (the side gear is hidden on YouTube). With ids,
it adds a `YouTubeLoopView` (a web player from `HimawariKit/NowPlaying.swift`) to every
window, pauses the player, and asks `youTubeTone` for a reading; with nil, it resumes the player
if playing and no scene is up, clears the tone and samples soon.

`addYouTube(to:)` (`:485-495`) creates the view with `fill: sizing == .fill`. In Fill mode it
covers the whole canvas; otherwise it stops below the menu-bar strip. It syncs the view's
play state to `playing`.

`syncYouTube(to:songPlaying:)` (`:477-480`) forwards Music's song position so the video follows
the song; it plays only if both Music is playing and the wallpaper is allowed to play.
AppDelegate calls it on every position update while YouTube shows.

`youTubeTone(_:)` (`:269-272`) asks `ToneReporter.showYouTube` to measure the video's
thumbnail (the web player's pixels can't be read), with a `stillCurrent` closure that checks the
first id is still showing when the thumbnail arrives.

`showingYouTube`, `showingScene` and `showingMusic` (`:482-483`, `:350`) are read-only flags for
AppDelegate.

### Playback and visibility

#### `setPlaying(_:)` (`:497-507`)

The playback decision from `PlaybackMonitor`. Stores `playing`, forwards it to YouTube views,
re-applies `running` to scenes (they follow `desktopVisible`, not `playing`), calls
`applySong()`, and plays the player only if there is a video and neither YouTube nor the scene
covers it; otherwise pauses, which leaves the last frame on screen. Because `PlaybackMonitor`
calls back on every 2-second evaluation, this runs every 2 s even when nothing changed.

#### `setDesktopVisible(_:)` (`:38-43`)

Guarded against no-ops. Sets `running` on scenes and re-runs `applySong()`. The comment states
the policy: the side gear and CD keep moving whenever the desktop can be seen, even while the
video is paused for the battery, because they are cheap.

### Now Playing, the side gear and audio levels

#### `setSong(_:)` and `applySong()` (`:377-419`)

`setSong` stores a new `SongInfo` (guarded by equality) and calls `applySong`. `applySong` is
the routine that reconciles the gear, the meters and the click catchers with the current
state; nearly every setter calls it.

1. `onMotion` = override set and neither YouTube nor scene. `gearShown` = a song exists and
   either the motion cover or the CD is up.
2. **Audio level start/stop.** `wanted` = gear shown, desktop visible and the song playing. If
   wanted: cancel any pending stop and call `audio.start()` (which returns immediately if
   already running, and refuses to retry within 60 s of a failure). If not wanted but the tap is
   running and no stop is pending, schedule `audio.stop()` 15 s later. The delay avoids tearing
   down and rebuilding the Core Audio tap and aggregate device on every brief change (switching
   windows can flip `desktopVisible`). The delayed stop logs and tells canvases and scenes
   `levelsChanged()`.

```swift
let stop = DispatchWorkItem { [weak self] in
    onMainActor {
        guard let self else { return }
        self.levelsStop = nil
        self.audio.stop()
        Log.write("levels: off")
        self.canvases.forEach { $0.levelsChanged() }
        self.scenes.forEach { $0.levelsChanged() }
    }
}
levelsStop = stop
DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: stop)
```
(`WallpaperManager.swift:394-405`)

3. If wanted but not running, log `audio.problem` (for example the permission denial text).
4. If the running state changed, log it and notify views so the gear switches between live
   levels and its own animation.
5. Assign `audio` as the `meterSource` of every canvas and scene.
6. Show the song in the canvases' side panels only on the motion cover (`onMotion ? song :
   nil`); scenes always get the song. `animating` follows `desktopVisible`.
7. `refreshControls()`.

#### `checkHearing()` (`:421-435`)

Called by the watchdog every 2 s. A Core Audio process tap that macOS has not allowed to hear
other apps does not fail; it delivers silence. `AudioLevels.hearing` is true while running and
either within 4 s of starting or within 4 s of last hearing sound
(`Sources/Himawari/AudioLevels.swift:146-150`). `checkHearing` skips the check while the song
is paused (silence is expected), and when `hearing` flips it logs (pointing the user at System
Settings ▸ Privacy & Security ▸ Screen & System Audio Recording) and tells views
`levelsChanged()`, so the meters never freeze: they animate by themselves when the tap is
silent.

#### The gear and its click catchers

`gear` (`:336`) collects the `NowPlayingSides` views from canvases and scenes. `gearActive`
(`:335`) is true when the desktop is visible, no YouTube is up, a song exists and some gear is
on screen; AppDelegate uses it to decide whether to poll Music's repeat/shuffle state.
`refreshControls()` (`:330-332`) hands gear, scenes and `gearActive` to
`GearControls.update`, which keeps one invisible window per control (at
`DesktopLayer.folders`, above Finder's icons) over the screen rect of each gear control and
each disc, moving kept ones and closing stale ones (`Sources/Himawari/GearControls.swift:33-67`).
This is needed because the wallpaper itself sits below Finder's icons and never gets clicks.
Refresh happens from `applySong()` and from the watchdog every 2 s, since the gear can move
when the video's shape or the scene layout changes. `showDeck(_:)` (`:339-347`) copies Music's
volume, bass, treble, repeat and shuffle into every gear view.

### The watchdog: `startWatchdog()` (`WallpaperManager.swift:437-456`)

Created once, on the first `start`, and runs every 2 s forever.

```swift
let size = self.player.currentItem?.presentationSize ?? .zero
if size.width > 0 { self.canvases.forEach { $0.videoSize = size } }
self.refreshControls() // the gear may have moved (new video shape, scene layout)
self.checkHearing()
guard let url = self.current, self.youtube == nil else { return }
let item = self.player.currentItem
if item == nil || item?.status == .failed || item?.error != nil {
    self.start(url)
} else if self.playing, self.player.rate == 0, item?.status == .readyToPlay {
    self.player.play() // stopped for no reason: nudge it
}
```
(`WallpaperManager.swift:443-453`)

Each tick: re-pushes the presentation size (a backstop for the KVO), refreshes the click
catchers, checks hearing, and then, unless YouTube is up, repairs the player: no item, a failed
item or an item with an error triggers a full `start` of the current URL; a ready item at rate
0 while it should be playing gets `play()`. The design goal (comment `:437`) is that the
wallpaper never stays black.

### Clock contrast readings

The desktop clock (a separate process, `HimawariClock`) needs to know how bright the wallpaper
is behind it to choose readable text. The protocol is distributed notifications
(`WallpaperTone` in `HimawariKit`): the clock posts its region as fractions of the main screen
(y down); Himawari answers with a 2-D brightness grid plus `focus` (mean luma behind the clock)
and `spread` (standard deviation).

#### `startToneSampling()` and `sampleTone()` (`:214-252`)

`startToneSampling` creates a repeating timer (3 s, or 10 s in Battery Saver) if none exists.
`sampleTone` does the measuring:

1. Skips while YouTube or the scene is up (those are measured once when they appear) or when
   there's no item or canvas.
2. If the current item is not the one the video output is attached to (the looper swaps items
   at every loop), it creates an `AVPlayerItemVideoOutput` asking for 64×64 BGRA pixel buffers,
   detaches the old output from the old item, attaches the new one, and returns: frames arrive
   from the next call. `AVPlayerItemVideoOutput` is AVFoundation's way to read decoded frames
   from a playing item without affecting display; requesting 64×64 makes AVFoundation scale
   down for us.
3. Converts the host clock (`CACurrentMediaTime()`) to item time and copies the pixel buffer
   for it, wrapping it in a `FrameSampler`.
4. Builds an `AmbientPalette` from the frame's edges and sends it to every canvas (this is
   what colours the Soft Colors bars).
5. Gets `(visible, full)` from the main canvas's `layoutFractions` and works out the bars'
   brightness: 0 for black, the palette's luma for ambient, and for blurred the whole frame's
   average luma times 0.55 (the backdrop layer's opacity).
6. `tone.show(frame, visible:full:fill:force: false)`; `ToneReporter` only posts when the
   reading changed noticeably (grid cell > 0.06 or focus/spread > 0.04,
   `ToneReporter.swift:69-72`).

`mainCanvas` (`:254`) is the canvas whose window is on `NSScreen.main` (the screen with the key
window), falling back to the first. `sampleSoon()` (`:259-267`) samples at 0.5, 1.2 and 2.5 s
after a change, so a new video is measured within a second; the first call usually only
attaches the output. `clockMoved(to:)` (`:256-257`) forwards the clock's region to
`ToneReporter`, which answers immediately.

### Notes and risks

- `WallpaperManager.swift:447-452` — the watchdog skips repair only when YouTube is up, not when
  the CD scene is. With the scene showing, the player is paused (`:300`) but its item is
  `.readyToPlay`, so the watchdog calls `play()` within 2 s whenever `playing` is true, and
  `setPlaying` (`:502-505`) pauses it again on the next 2 s evaluation. The hidden video is
  decoded under the disc for part of every cycle.
- `WallpaperManager.swift:181` — the muted continuation resumes playback on `self.playing`
  alone, ignoring `youtube`/`sceneArt` (compare `:208`). Going from a motion cover to the CD
  (`setOverride(nil)` then `setScene(art)`) can resume the hidden video after `setScene`
  paused it.
- `WallpaperManager.swift:166-180` — on the muted path the queue is emptied before the
  asynchronous `pictureOnly` finishes, so the screen is briefly black. If that load ever took
  over 2 s, the watchdog would see `item == nil` and call `start` again, cancelling the
  pending result each time.
- `WallpaperManager.swift:210,438` — the watchdog (and with it `checkHearing` and the periodic
  `refreshControls`) is only started by `start(_:)`. A user with no chosen video whose first
  music scene is the CD gets no hearing checks or catcher refresh until some video starts.
- `WallpaperManager.swift:146-153` — on entering motion artwork, the canvases switch to the
  music sizing before the stream is resolved, so your own video is shown letterboxed for the
  duration of the playlist fetch (the reverse of the flash the comment at `:140` avoids).
- `WallpaperManager.swift:497-507` — `setPlaying` is not change-guarded and is called every 2 s
  by `PlaybackMonitor`, so `applySong()`, `GearControls.update` and `player.play()/pause()` run
  every 2 s.
- `WallpaperManager.swift:131` — `powerChanged` always reloads the motion stream, even when the
  1080-pixel cap makes no difference (screens at or below 1080 px), interrupting the loop.
- `WallpaperManager.swift:86-90` — the screen-change observer token is discarded; harmless for
  a singleton but not removable.
- `WallpaperManager.swift:254` — tone readings come from the canvas on `NSScreen.main` (the
  key-window screen); the clock's region is also relative to "the main screen", but if the two
  processes disagree about which screen that is, the reading describes the wrong picture.

---

## Sources/Himawari/VideoCanvas.swift

**Purpose.** The content view of each wallpaper window. It decides where the video sits on one
screen, what fills the space around it, and where the side gear goes. 156 lines.

**Where it sits.** Created only by `WallpaperManager.makeWindow(for:)`; one per screen. The
manager sets its properties; `MusicScene` and `YouTubeLoopView` are added on top of it as
subviews by the manager.

**Design decisions.** It is a layer-hosting view that arranges Core Animation layers by hand
instead of using Auto Layout: there are no constraints, so it rearranges immediately on any
size or property change (comment `:88-89`). Both the sharp video and the blurred backdrop are
`AVPlayerLayer`s on the same player, so blur costs no extra decode. Blurring is done on a copy
at one tenth of the size and scaled up ten times (`:78-82`), about 1/100 of the pixel work,
which is invisible because the result is a blur.

### `VideoCanvas` (class, `NSView`, `@MainActor`, `final`)

**Layer tree** (back to front):

```
layer (black, masksToBounds)
 ├─ backdrop : AVPlayerLayer   aspect-fill, opacity 0.55, 1/10 size ×10 scale, CIGaussianBlur 4.5
 ├─ ambient  : AmbientLayer    soft-colour blobs (hidden unless barFill == .ambient)
 └─ band     : CALayer         masksToBounds: the visible slice of the video
     └─ video : AVPlayerLayer  gravity .resize, framed exactly by frames()
 (subview) NowPlayingSides     the side gear, when a song shows on the motion cover
```

**Stored state.**

| Property | Type | Meaning |
|---|---|---|
| `backdrop` | `AVPlayerLayer` | Blurred, enlarged copy of the video for the Blurred Video fill. |
| `video` | `AVPlayerLayer` | The sharp video. |
| `band` | `CALayer` | Clipping container for the visible part of the video. |
| `sizing` | `VideoSizing` | Mode; `didSet` re-arranges on change. Defaults to `.fitWidth` but the manager sets it at once. |
| `ambient` | `AmbientLayer` | Soft Colors fill. |
| `barFill` | `BarFill` | Fill mode; re-arranges on change. |
| `ambientMotion` | `Bool` | Forwards to `ambient.animated`. |
| `sides` | `NowPlayingSides?` | The side gear view. |
| `onClick` | `(() -> Void)?` | Mouse-down handler (clicks only arrive while files are hidden). |
| `sidesLively` | `Bool` | Forwards to `sides?.lively` (Battery Saver). |
| `meterSource` | `AudioLevels?` | Forwards to `sides?.meterSource`. |
| `topInset` | `CGFloat` | Height of the menu-bar / notch strip. |
| `videoSize` | `CGSize` | The item's presentation size; re-arranges on change. |
| `backdropShrink` | `CGFloat` (static, 10) | Downscale factor for the blur. |

**Lifecycle and threading.** Owned by its window (as `contentView`) and by the manager's
`canvases` array; discarded on `rebuildWindows`. Main actor only.

### Initialiser (`VideoCanvas.swift:62-84`)

Creates both player layers on the given player, makes the view layer-backed
(`wantsLayer = true`), and sets `layerUsesCoreImageFilters = true`: on macOS, a layer's
`filters` array (Core Image filters applied by the render server) is ignored unless the hosting
view opts in. It sets a black, clipping root layer and `contentsScale` to the screen's backing
scale on both player layers ("a hand-added layer defaults to 1×", which would look soft on
Retina), assembles the tree, and configures the backdrop: aspect-fill, opacity 0.55,
`contentsScale = 1` (overriding the line above, deliberately low-resolution), a 10× scale
transform and a `CIGaussianBlur` of radius 4.5 (≈45 screen points after scaling). The video
layer uses `.resize` gravity because `arrange()` computes its frame exactly.

`init?(coder:)` is unavailable (`fatalError()`), as for every programmatic view in the app.

### Events

`acceptsFirstMouse(for:)` returns true so the first click on a non-active app's window is
delivered rather than merely activating it; `mouseDown(with:)` calls `onClick`. The window
ignores mouse events except while the files are hidden, so in practice this is "click the
wallpaper to bring the files back".

### Side gear: `setSong(_:animating:)`, `levelsChanged()`, `gear`

`setSong` with nil removes the gear. With a song it lazily creates a full-size, autoresizing
`NowPlayingSides`, copies `sidesLively` and `meterSource` to it, adds it, re-arranges (to place
it), then sets `animating` and shows the song. `levelsChanged()` forwards to the gear; `gear`
exposes it for the click catchers.

### Layout: `arrange()`, `frames()`, `videoFrame()`

`setFrameSize(_:)` and `layout()` both call `arrange()`; so do the `didSet`s of `sizing`,
`barFill`, `topInset` and `videoSize` when the value actually changes.

#### `arrange()` (`VideoCanvas.swift:100-117`)

Inside a `CATransaction` with actions disabled (so layers jump to their new frames instead of
animating implicitly, Core Animation's default for standalone layers):

1. Sizes the backdrop to `(bounds + 120 pt) / 10` and centres it; with the 10× transform this
   overscans by 60 pt on each side so the blur's soft edges are off-screen.
2. Gets `(visible, full)` from `frames()`; the band takes `visible`, and the video layer takes
   `full` translated into the band's coordinates. When the video is cropped (`fitWidth` with a
   tall video), the band clips it.
3. `covered = visible.contains(bounds)`: no bars. The backdrop is visible only for
   `.blurred` and not covered; the ambient layer only for `.ambient` and not covered, in which
   case it is arranged around the visible rect.
4. Places the gear around the visible rect.
5. Logs the sizing decision.

#### `frames()` and `videoFrame()` (`:119-155`)

All rectangles are in the view's AppKit coordinates (origin bottom-left). The usable area for
non-Fill modes is the bounds minus `topInset` at the top, so the picture is never hidden under
the notch.

| Mode | Size rule | Visible slice | Bars |
|---|---|---|---|
| `.widescreen` (default) | Fit the whole video in the area below the strip (`frames` handles it directly) | whole video | top/bottom for wide videos, sides for square/tall ones |
| `.fit` | Fit by the limiting dimension in the area | whole video | around the video |
| `.fitWidth` | Width = area width, height from aspect | `full ∩ bounds` (tall videos cropped) | top/bottom when shorter |
| `.fill` | Cover the full bounds (aspect fill), notch strip included | `bounds` | none |

All results are centred and passed through `.integral` so layers land on whole points. If the
video size is unknown (zero), both rects are the bounds.

#### `layoutFractions` (`:47-56`)

Converts `(visible, full)` into fractions of the screen with y running down (flipping AppKit's
y), the coordinate system `ToneReporter` and `WallpaperTone` use. Returns the unit rect twice
for a zero-sized view.

`showPalette(_:)` forwards a palette to the ambient layer.

### Notes and risks

- `VideoCanvas.swift:148` — the `.widescreen` case in `videoFrame()` is unreachable, since
  `frames()` returns early for widescreen.
- `VideoCanvas.swift:13` — the comment "Widescreen trims tall videos" is out of date: widescreen
  never crops (`:123-125`); only `.fitWidth` trims.
- `VideoCanvas.swift:114-115` — `arrange()` writes a log line on every call, and it is called
  from `layout()`, `setFrameSize` and four property observers.
- `VideoCanvas.swift:135` — in `.fitWidth` the visible slice is clipped to `bounds`, not to the
  area below `topInset`, so a tall video extends under the notch strip, unlike the other bar
  modes.

---

## Sources/Himawari/AmbientFill.swift

**Purpose.** Implements the "Soft Colors (Apple Music Style)" bar fill: a small palette taken
from the video's edges, and a layer of four large blurred blobs in those colours that drift and
breathe slowly in the bars. 161 lines.

**Where it sits.** `AmbientPalette.from` is called by `WallpaperManager.sampleTone` (video
frames) and by `MusicScene` (cover art). `AmbientLayer` is created by each `VideoCanvas` and
also used by `MusicScene` for its backdrop.

**Design decision.** All motion is a Core Animation animation, which the window server
renders without waking the app; frame rate is capped at 8–15 fps (preferred 12) since a drift
this slow looks the same at 12 fps as at 120 (`:155-156`). The alternative, a CIFilter blur
or a Metal shader, would cost per-frame GPU work.

### `AmbientPalette` (struct, `Equatable`)

| Property | Type | Meaning |
|---|---|---|
| `sides` | `[SIMD3<Double>]` | Left-top, left-bottom, right-top, right-bottom colours (sRGB 0…1), for bars at the sides. |
| `ends` | `[SIMD3<Double>]` | Top-left, top-right, bottom-left, bottom-right, for bars above and below. |
| `neutral` (static) | `AmbientPalette` | A dark purple-grey (0.12, 0.10, 0.14) everywhere, the starting palette. |

- `from(_:)` (`:16-24`) averages eight strips of the frame, each 12 % deep along an edge, half
  the edge long, using `FrameSampler.average` (an 8×8 sample grid per region, v running down),
  and passes each average through `mood`.
- `mood(_:)` (`:34-41`) keeps the hue, raises saturation by 20 % (capped at 1), and remaps
  brightness to `0.12 + min(b, 0.7) × 0.5`, i.e. 0.12–0.47, so the glow is never black and
  never competes with the video.
- `luma` (`:27-31`) is the Rec. 709 luma of the mean of all eight colours times 0.8, an
  approximation of what the darker-than-blobs background does to the overall brightness; used
  for clock readings.
- `differs(from:)` (`:43-47`) is true if any channel of any colour moved by more than 0.04, so
  small frame-to-frame noise does not restart the colour animation.

### `AmbientLayer` (class, `CALayer`, `final`)

**Responsibility.** Draws the glow in the bars. Not `@MainActor`-annotated, but only touched
from main-actor code.

| Property | Type | Meaning |
|---|---|---|
| `blobs` | `[CALayer]` (4) | Coloured squares, each masked to a soft dot. |
| `masks` | `[CALayer]` (4) | Mask layers whose contents is `softDot`. |
| `softDot` (static) | `CGImage?` | A 256×256 alpha-only radial gradient (opaque → 50 % at 0.45 → clear), drawn once. |
| `palette` | `AmbientPalette` | Current colours. |
| `sideways` | `Bool` | Bars at the sides (true) or above/below. |
| `driftSize` | `CGSize` | How far blobs drift; zero until arranged. |
| `animated` | `Bool` | Drift on/off (off in Battery Saver); restarts the drift on change. |

**Methods.**

- `init()` (`:75-84`) masks each blob with a soft dot, adds them, and applies the colours
  without animation. `init(layer:)` is the initialiser Core Animation uses to make
  presentation copies; it just calls super.
- `arrange(in:around:)` (`:89-114`) sets the layer frame to the bounds and decides `side` (the
  video is inset from the left by more than 1 pt). For side bars it centres blobs in each bar at
  72 % and 28 % of the height, diameter 95 % of the screen height; for top/bottom bars at 28 %
  and 72 % of the width, diameter 55 % of the width. Blobs are far larger than the bars and
  overlap the video area, but the canvas draws the video band on top. The drift size is 35 % of
  the bar width by 12 % of the height (sides) or 10 % of the width by 60 % of the bar height
  (top/bottom), with minimum bar sizes of 40/20 pt. If orientation or drift size changed it
  re-applies colours (picking `sides` or `ends`) and restarts the drift.
- `show(_:)` (`:116-120`) applies a new palette with a 2.5 s colour cross-fade, only if it
  `differs`.
- `isHidden` override (`:122`) restarts (or stops) the drift when shown or hidden, so hidden
  layers carry no animations.
- `applyColors(animated:)` (`:124-136`) sets each blob's colour at 95 % alpha and the layer's
  own background to the mean colour × 0.55, inside a transaction whose duration is 2.5 s or 0.
- `restartDrift()` (`:138-160`) removes animations and, if animated, visible and arranged,
  adds to each blob a position drift (`byValue`, alternating sign per blob, period
  19 + 4.7·i s) and a "breathing" scale from 1 to 1.15/1.20 (period 23 + 3.1·i s), both
  autoreversing forever with ease-in-out and the 8–15 fps frame-rate range. The unequal periods
  mean the combined pattern doesn't visibly repeat.

```swift
let drift = CABasicAnimation(keyPath: "position")
drift.byValue = NSValue(point: CGPoint(x: sign * driftSize.width, y: -sign * driftSize.height))
drift.duration = 19 + Double(i) * 4.7 // unequal periods: the pattern never visibly repeats
```
(`AmbientFill.swift:143-145`)

### Notes and risks

- `AmbientFill.swift:16-24` — the palette is computed from the whole decoded frame, so in
  `.fitWidth` with a cropped tall video the edge colours come from parts not on screen.
- `AmbientFill.swift:53` — `AmbientLayer` has no actor annotation; it relies on callers being on
  the main thread.

---

## Sources/Himawari/PlaybackMonitor.swift

**Purpose.** Decides whether the wallpaper video should be playing and gives a human-readable
reason for the menu, and separately whether the desktop can be seen at all. 135 lines.

**Where it sits.** Created by `AppDelegate` (`:14`), started at launch (`:67`), and asked to
re-evaluate after many menu actions and after every music change (`AppDelegate.swift:214`).
Its `onChange` drives `WallpaperManager.setDesktopVisible` and `setPlaying`
(`AppDelegate.swift:61-66`); `reason` appears in the status-item tooltip and menu.

**Design decision.** Polling every 2 s rather than event-driven, because window layout and
power source "change without notifications we can rely on" (comment `:33-34`). Lock and
display sleep, which do have notifications, are tracked by observers and trigger an immediate
evaluation.

### `PlaybackMonitor` (class, `@MainActor`, `final`)

| Property | Type | Meaning |
|---|---|---|
| `onChange` | `((Bool) -> Void)?` | Called with play (true) / pause (false) after every evaluation. |
| `reason` | `String` (private(set)) | "Playing", "Paused", "Screen locked", … |
| `desktopVisible` | `Bool` (private(set)) | Not locked, displays awake, and not every screen covered. |
| `screenLocked` | `Bool` | From distributed lock notifications. |
| `displaysAsleep` | `Bool` | From workspace sleep/wake notifications. |
| `timer` | `Timer?` | The 2 s poll. |

**Lifecycle.** App lifetime; observers and timer never removed.

### `start()` (`:24-39`)

Observes `NSWorkspace.screensDidSleepNotification` / `screensDidWakeNotification` on the
workspace notification centre (display sleep, which also precedes system sleep), and the
distributed notifications `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` (posted by
the login window; widely used, though not formally documented). Then schedules the 2 s timer
and evaluates once.

`observe(_:_:_:)` (`:59-67`) is a helper: adds a main-queue observer that applies a mutation to
`self` and re-evaluates, capturing `self` weakly.

### `evaluate()` — the pause rules (`:41-57`)

The rules are a priority chain; the first that applies names the reason:

| # | Condition | Reason |
|---|---|---|
| 1 | `Settings.userPaused` | "Paused" |
| 2 | screen locked | "Screen locked" |
| 3 | displays asleep | "Display asleep" |
| 4 | `pauseOnBattery` (default on) and on battery power | "Paused on battery" |
| 5 | `pauseWhenCovered` (default on) and every screen covered | "Paused (desktop covered)" |
| 6 | `pauseWhenCovered` and Battery Saver and main screen > 60 % covered | "Paused (Battery Saver, mostly covered)" |
| — | otherwise | "Playing" |

```swift
(s.pauseWhenCovered && PowerState.saving && Self.mainScreenCoveredFraction() > 0.6)
    ? "Paused (Battery Saver, mostly covered)" :
nil
```
(`PlaybackMonitor.swift:51-53`)

Rule 6 only matters with Low Power Mode on mains power (on battery, rule 4 usually fires
first unless the user turned it off). `desktopVisible` is computed independently and ignores
battery rules, so the CD and gear keep animating while the video is paused for power. Finally
`onChange` is called unconditionally.

### Checks

- `onBattery()` (`:71-76`): IOKit power sources. `IOPSCopyPowerSourcesInfo` returns a snapshot
  (owned, hence `takeRetainedValue`), `IOPSGetProvidingPowerSourceType` names the current
  source (unowned); compared with `kIOPMBatteryPowerKey`. Desktop Macs return no info → false.
- `mainScreenCoveredFraction()` (`:80-103`): lists on-screen windows with
  `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], …)`, keeps those at
  layer 0 (normal app windows), not Himawari's, and with alpha > 0.1, and samples a 12×8 grid of
  points over the main screen's visible frame (converted from AppKit bottom-left coordinates to
  CoreGraphics top-left ones using the first screen's height). Overlapping windows are not
  double-counted because each grid point is counted once.
- `allScreensCovered()` (`:107-134`): same filtering; true when, for every screen, a single
  window covers at least 95 % of the visible frame. Window bounds and owner PIDs do not need
  Screen Recording permission; only window titles would (comment `:106`).

### Notes and risks

- `PlaybackMonitor.swift:55` — `allScreensCovered()` is called a second time for
  `desktopVisible` after possibly being called in the chain at `:48`: two window-list copies per
  2 s tick.
- `PlaybackMonitor.swift:56` — `onChange` fires every 2 s whether or not the decision changed
  (see the `setPlaying` note above).
- `PlaybackMonitor.swift:71-76` duplicates `PowerState.checkBattery`
  (`PowerState.swift:41-45`); rule 4 reads the battery live while rule 6 reads
  `PowerState.saving`, whose battery part can be up to 20 s stale.
- `PlaybackMonitor.swift:129-131` — "covered" requires one window to cover 95 % by itself; two
  side-by-side windows filling a screen do not count.

---

## Sources/Himawari/DesktopPeek.swift

**Purpose.** "Click an empty spot on the desktop: the files and folders disappear and it's just
the live wallpaper. Click again … and they're back" (`:4-5`). 112 lines.

**Where it sits.** Created by `AppDelegate` (`:15`); `enabled` mirrors the
`clickToClearDesktop` setting (default on). `onChange(true)` calls `wallpaper.setClear(true)`;
`onWallpaperClick` calls `setClear(false)` if cleared (`AppDelegate.swift:80-83`).

**Design.** Finder draws all desktop icons in one full-screen window at the desktop-icon
level, so "a click landed on Finder's desktop window" is easy to detect from window geometry,
but it cannot tell an icon from empty space. Asking Finder over AppleScript afterwards whether
anything is selected settles that, since clicking empty space deselects everything. Watching
clicks with a global monitor needs no permission; controlling Finder needs a one-time
Automation (Apple Events) consent from TCC, macOS's privacy permission system.

### `DesktopPeek` (class, `@MainActor`, `final`)

| Property | Type | Meaning |
|---|---|---|
| `onChange` | `((Bool) -> Void)?` | Clear (true) requested. (Only true is ever sent here.) |
| `monitor` | `Any?` | Global mouse monitor token. |
| `localMonitor` | `Any?` | Local mouse monitor token. |
| `onWallpaperClick` | `(() -> Void)?` | A click on the raised wallpaper. |
| `downAt` | `NSPoint?` | Where a candidate click went down. |
| `enabled` | `Bool` | Installs / removes both monitors. |

### `enabled` (`:21-45`)

On enable, installs:

- **A local monitor** (`NSEvent.addLocalMonitorForEvents`) for left mouse-down. Local monitors
  see events dispatched to Himawari's own windows (global monitors never do). If the event's
  window level is below `.normal`, i.e. one of Himawari's desktop-level windows, it calls
  `onWallpaperClick`. It returns the event unchanged so normal handling continues. The
  `??` binds tighter than `<`, so a nil window compares as 0, which is not below normal.
- **A global monitor** (`addGlobalMonitorForEvents`) for left down and up in other apps'
  windows (here: Finder's desktop). Global mouse monitoring requires no Accessibility
  permission (only key events do). It reads `NSEvent.mouseLocation` (global AppKit
  coordinates) and forwards type, location and click count to `handle`.

On disable, removes both monitors.

### `handle(_:at:clicks:)` (`:47-61`)

```swift
if type == .leftMouseDown {
    downAt = clicks == 1 && Self.windowUnder(point).0 ? point : nil
    return
}
// A plain click: not a drag (a selection rectangle), not a double-click.
guard let start = downAt, hypot(point.x - start.x, point.y - start.y) < 5 else { downAt = nil; return }
downAt = nil
```
(`DesktopPeek.swift:48-54`)

A mouse-down records its location only if it is a single click and Finder's desktop window is
frontmost under the pointer. A mouse-up within 5 points is a plain click (not a rubber-band
selection or double-click). After 0.15 s (time for Finder to update its selection), it asks
Finder for the selection count; "0" requests clearing; nil (osascript failed, e.g. permission
denied) is logged with a hint.

### `windowUnder(_:)` (`:63-94`)

Walks `CGWindowListCopyWindowInfo([.optionOnScreenOnly], …)`, which is ordered front to back,
after flipping the point into top-left coordinates. It skips Himawari's own windows (by PID)
and nearly transparent ones (alpha ≤ 0.01), and finds the first window containing the point.
If that window is above the desktop-icon level, it is a blocker (an app window, the Dock, the
menu bar), except windows whose owner name starts with "Himawari" (the clock helper is a
different process, so the PID check misses it) and Notification Center's full-screen
transparent widget canvas (≥ 95 % of the screen), which are looked past. Otherwise the answer
is whether that window belongs to Finder at exactly the desktop-icon level. The second tuple
element is a description intended for logging. Owner names are available without Screen
Recording permission.

### `finderSelectionIsEmpty(_:)` (`:96-111`)

On a global `.userInitiated` queue, runs `/usr/bin/osascript -e 'tell application "Finder" to
return (count of (get selection)) as text'`, discards stderr, waits for exit, reads stdout,
trims it, returns it only if the exit status was 0, and calls the completion on the main queue.
The first run triggers macOS's "Himawari wants to control Finder" prompt. Using a subprocess
rather than `NSAppleScript` keeps the blocking Apple Event off the main thread.

### Notes and risks

- `DesktopPeek.swift:28` — the local monitor fires for any Himawari window below `.normal`,
  which includes the `GearControls` catchers (`DesktopLayer.folders`). While files are hidden,
  pressing a gear button or the disc also brings the files back.
- `DesktopPeek.swift:78` — `level != desktopLevel` is always true when `level > desktopLevel`,
  so the Finder clause in the condition is redundant.
- `DesktopPeek.swift:28-30` and `VideoCanvas.swift:22` — a click on the raised wallpaper is
  handled twice (local monitor and `mouseDown` → `onClearedClick`); harmless because
  `setClear` is guarded.
- `DesktopPeek.swift:104-106` — `try? p.run()` failure leaves `waitUntilExit` on a process that
  never started; `terminationStatus` on an unlaunched `Process` raises an Objective-C exception.
- `DesktopPeek.swift:100` — `selection` is Finder's selection in its frontmost window or the
  desktop; the check assumes the desktop click made the desktop frontmost, with a fixed 0.15 s
  wait.

---

## Sources/HimawariKit/PowerState.swift

**Purpose.** A single definition of "Battery Saver": the Mac is on battery *or* Low Power Mode
is on. Everything that costs power checks `PowerState.saving` and subscribes to changes.
46 lines. In `HimawariKit` so the clock helper can use it too.

**Callers in this chapter.** `WallpaperManager` (bar fill, stream cap, tone interval, scene and
gear liveliness), `PlaybackMonitor` (rule 6), `AppDelegate` (subscribes, and skips YouTube in
Battery Saver, `AppDelegate.swift:197`).

### `PowerState` (caseless `public enum`, `@MainActor`)

A caseless enum is a namespace that cannot be instantiated.

| Member | Type | Meaning |
|---|---|---|
| `onBattery` | `static Bool` (public get) | Cached; initialised lazily by `checkBattery()`, refreshed every 20 s once watching. |
| `lowPowerMode` | `static Bool` (computed) | `ProcessInfo.isLowPowerModeEnabled`, read live. |
| `saving` | `static Bool` (computed) | `onBattery || lowPowerMode`. |
| `observers` | `[@MainActor () -> Void]` | Registered change handlers. |
| `watching` | `Bool` | Whether the notification and timer are installed. |
| `lastSaving` | `Bool?` | Last value broadcast. |

- `onChange(_:)` (`:18-32`) appends the handler and, the first time, observes
  `.NSProcessInfoPowerStateDidChange` (posted when Low Power Mode toggles) on the main queue and
  starts a 20 s timer that refreshes `onBattery` and fires on change.
- `fire()` (`:35-39`) broadcasts only when `saving` actually differs from the last broadcast
  value. The first call always fires because `lastSaving` starts nil.
- `checkBattery()` (`:41-45`) is the same IOKit query as `PlaybackMonitor.onBattery()`.

### Notes and risks

- `PowerState.swift:26` — unplugging can take up to 20 s to switch Battery Saver on.
- `PowerState.swift:14-19` — handlers can only be added, never removed; fine for the current
  app-lifetime callers.

---

## Sources/HimawariKit/DesktopWindow.swift

**Purpose.** Shared desktop-window plumbing: named level offsets, a borderless transparent
desktop window, a hosting view that accepts the first click, and the entry point for
background helper processes. 71 lines.

**Where it sits.** `DesktopLayer` is used by `GearControls` (`GearControls.swift:213`) and the
clock (`HimawariClock/DesktopClock.swift:87,102`). `DesktopWindow` is used by the clock.
`runBackgroundService` is the clock helper's `main` (`HimawariClock/main.swift:6`). The
wallpaper's own windows do not use `DesktopWindow` because they must be opaque, non-activating
panels.

### `DesktopLayer` (caseless enum)

Constants `video = 1`, `decorations = 2`, `folders = 22`, `overlay = 23`, offsets above
`CGWindowLevelForKey(.desktopWindow)`; `level(_:)` turns an offset into an `NSWindow.Level`.
The comment records the key fact used throughout this chapter: Finder's icons are at +20 and
swallow every desktop click, so anything clickable must sit above it (the table under "Window
levels" above).

### `DesktopWindow` (class, `NSWindow`, `final`)

`init(layer:interactive:)` makes a borderless, buffered window at the given layer with the
same collection behaviour as the wallpaper panels (all Spaces, stationary, ignores cycling, no
full screen), click-through unless `interactive`, transparent (`isOpaque = false`, clear
background), shadowless, not released on close. `canBecomeKey` is overridden to return true
for interactive windows, because borderless windows refuse key status by default and an
opened folder needs Escape. `host(_:)` installs a SwiftUI view in a `FirstClickHostingView`
and sizes the window to the view's fitting size.

### `FirstClickHostingView` (generic class, `NSHostingView<Content>`)

Overrides `acceptsFirstMouse(for:)` to true, so a click on a desktop control works immediately
instead of only activating the background app.

### `runBackgroundService(onQuit:_:)` (`:55-71`)

Returns `Never`. On the main actor it sets the activation policy to `.accessory` (no Dock or
menu-bar presence but still able to take key events), ignores the default `SIGTERM` action
and installs a `DispatchSource` signal source on the main queue that runs `onQuit` and exits,
so a `launchd` stop can undo changes; builds the service object with `make()` and keeps both it
and the signal source alive with `withExtendedLifetime` around `app.run()`. The final
`exit(0)` covers `run()` returning.

```swift
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler {
    onMainActor { onQuit() }
    exit(0)
}
term.resume()
```
(`DesktopWindow.swift:60-66`)

Ignoring the signal first is required: a dispatch signal source only observes signals; without
`SIG_IGN` the default action would kill the process before the handler runs.

### Notes and risks

- `DesktopWindow.swift:9-12` — `video`, `decorations` and `overlay` have no users in this repo
  (the wallpaper computes its +1 itself, `WallpaperManager.swift:77`); the doc comment on
  `decorations` says "the clock", but the clock uses `folders`.

---

## Sources/HimawariKit/ScreenGeometry.swift

**Purpose.** One computed property, 7 lines:

```swift
public var menuBarStripHeight: CGFloat { max(safeAreaInsets.top, frame.maxY - visibleFrame.maxY) }
```
(`ScreenGeometry.swift:6`)

`safeAreaInsets.top` is the camera housing (notch) height on notched MacBooks;
`frame.maxY - visibleFrame.maxY` is the space taken by the menu bar (`visibleFrame` excludes
the menu bar and the Dock). Taking the maximum handles both. **Callers:**
`WallpaperManager.makeWindow` (canvas `topInset`), `addScene` and `addYouTube` (insets), and
`ToneReporter.showYouTube` (where the YouTube video sits). It is an `NSScreen` extension in
the shared library so the clock could use the same rule.

### Notes and risks

- `ScreenGeometry.swift:6` — with an auto-hiding menu bar on a screen without a notch, the
  height is 0 and the video extends to the top edge; on a secondary display without a menu bar
  it is also 0. Both appear intended.

---

## Sources/HimawariKit/DesktopLayout.swift

**Purpose.** A shared map of reserved strips on the main screen ("widgets", "folders",
"taskbar") so that separate Himawari processes can avoid each other, and a helper to compute
the remaining free area. 62 lines.

**Where it sits.** In this repository only the desktop clock reads it
(`DesktopLayout.freeArea(of:)`, `HimawariClock/DesktopClock.swift:69,90`) to place itself.
`setZone` has no caller here; the zones are published by components that now live outside
this repo (the Desktop Shell), so in a standalone install `freeArea` is just `visibleFrame`
unless old zone values remain in the shared preferences.

**Design.** Zones live in the shared preferences domain `local.dhairyabhatia.desktop` (via
`HimawariKit.Settings`), which works across processes; a change is announced with
`Settings.broadcastChange()`, a distributed notification, so other processes re-tile.

### `DesktopLayout` (caseless enum, `@MainActor`)

- `Zone` — `widgets`, `folders`, `taskbar` (`String`, `CaseIterable`). `gap` = 8 pt.
- `setZone(_:_:)` (`:19-25`) stores `NSStringFromRect(rect.integral)` (or nil) under
  `"zone.<name>"`, but only if the stored string differs, then broadcasts. The equality check
  prevents a re-tile loop where every process re-publishes in response to the others.
- `zone(_:)` (`:27-29`) reads it back; `Settings.string` calls `synchronize()` first to pick up
  another process's write.
- `freeArea(of:excluding:)` (`:32-38`) starts from the screen's `visibleFrame` and cuts out each
  zone not excluded. Note it takes a `screen` argument but zones are documented as main-screen
  rectangles.
- `cut(_:from:)` (`:42-55`) assumes the zone is attached to an edge. It computes how much to
  trim from each side to clear the zone plus the gap, scores each option by area lost, discards
  options that leave nothing, and picks the cheapest.
- `toTopLeft(_:)` (`:58-61`) flips an AppKit rect into CoreGraphics / Accessibility
  coordinates using the first screen's height. No caller in this repo.

```swift
let options: [(lost: CGFloat, result: NSRect)] = [
    (trimLeft * area.height, NSRect(x: area.minX + trimLeft, y: area.minY, width: area.width - trimLeft, height: area.height)),
    (trimRight * area.height, NSRect(x: area.minX, y: area.minY, width: area.width - trimRight, height: area.height)),
    (trimBottom * area.width, NSRect(x: area.minX, y: area.minY + trimBottom, width: area.width, height: area.height - trimBottom)),
    (trimTop * area.width, NSRect(x: area.minX, y: area.minY, width: area.width, height: area.height - trimTop)),
]
```
(`DesktopLayout.swift:48-53`)

### Notes and risks

- `DesktopLayout.swift:19,58` — `setZone` and `toTopLeft` have no callers in this repo; stale
  `zone.*` keys written by an older build with the Desktop Shell would still shrink the clock's
  free area.
- `DesktopLayout.swift:42-55` — a zone in the middle of the area (not edge-attached) is
  handled by trimming a whole side, which can discard much more space than the zone.

---

## Summary of the engine's power policy

| Situation | Video | Bars | CD / gear motion | Audio tap | Tone sampling |
|---|---|---|---|---|---|
| Normal, visible | plays | chosen fill, ambient drifts | animates | on if gear shown and song playing | every 3 s |
| Battery Saver (battery or Low Power Mode) | plays unless rules 4/6 pause; streams ≤ 1080 px; no YouTube | blurred → soft colours, no drift | `lively = false` | unchanged | every 10 s |
| On battery with "pause on battery" | paused | static | still animates if visible | unchanged | timer runs, no new frames |
| Every screen covered | paused (if setting on) | static | stopped (`desktopVisible` false) | stops after 15 s | timer runs |
| Locked / displays asleep | paused | static | stopped | stops after 15 s | timer runs |
| YouTube showing | player paused, web view plays | n/a | gear hidden | stops after 15 s | thumbnail once |
| CD scene showing | player paused (see watchdog note) | scene backdrop | animates while visible | on while song plays | cover once |
