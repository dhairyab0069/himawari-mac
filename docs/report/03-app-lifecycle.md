# 3 · Start-up, menus and settings

This chapter covers the code that starts Himawari, builds its menus, connects the Music app to the
wallpaper and the gear back to Music, and keeps the user's choices: `main.swift`,
`AppDelegate.swift`, the two `Settings.swift` files, `Log.swift` and `MainThread.swift`. Together
they are about 975 lines, but `AppDelegate` is the hub that every other part of the app is wired
through, so understanding it is the key to the rest of the report.

Line numbers are for commit `22c0feb` (two fix commits after the `v1.1.3` tag; none of the files in
this chapter changed in them).

## Sources/Himawari/main.swift

11 lines. The program's entry point: Swift runs the top-level code of the file named `main.swift`
in an executable target as the process's `main`.

```swift
// A menu-bar-only app: no Dock icon, no main window.
onMainActor {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() } // app.delegate is weak; keep ours alive
}
```
(`main.swift:4-11`)

What it does, step by step:

1. `onMainActor { … }` (from `MainThread.swift`, below) runs the block as main-actor code.
   `AppDelegate` is `@MainActor`, so its initializer can only be called synchronously from the
   main actor. Top-level code in Swift 5 mode is not reliably treated as main-actor isolated, and
   `MainActor.assumeIsolated` performs the runtime executor check that the project found to
   crash (see `MainThread.swift`), hence the project's own helper.
2. `NSApplication.shared` creates the application object, connects to the window server and sets
   up the main run loop.
3. `AppDelegate()` runs the delegate's property initializers, which create the long-lived parts
   of the app (the wallpaper manager and its windows, the playback monitor, the desktop-click
   watcher, the Music connection, the clock helper object). This happens *before* the run loop
   starts. `MusicNowPlaying.init` already starts the Perl helper and an AppleScript read.
4. `app.delegate = delegate`. `NSApplication.delegate` is a weak reference, so nothing else would
   keep the delegate alive.
5. `setActivationPolicy(.accessory)`: no Dock icon and no menu bar, matching `LSUIElement` in the
   `Info.plist`. `AppDelegate.applyDockVisibility` may later switch to `.regular`.
6. `withExtendedLifetime(delegate) { app.run() }` starts the event loop and guarantees the
   optimizer cannot release `delegate` while it runs. `run()` does not return in practice:
   "Quit" calls `NSApplication.terminate`, which calls `applicationWillTerminate` and then
   `exit()`.

There is no storyboard, nib or `NSPrincipalClass`; the app needs none because it has no windows
of the normal kind.

### Notes and risks

- `main.swift:5`: `onMainActor` contains a `precondition(Thread.isMainThread)`. Top-level code
  always runs on the main thread, so it cannot fire here.

## Sources/Himawari/AppDelegate.swift

608 lines; one class, `AppDelegate`, `@MainActor final class AppDelegate: NSObject,
NSApplicationDelegate, NSMenuDelegate`. It is:

- the **application delegate**: launch, termination, the Dock menu, re-open from the Dock;
- the **menu delegate** of the status item's menu, which it rebuilds every time it opens;
- the **owner** of the wallpaper (`WallpaperManager`), the pause rules (`PlaybackMonitor`), the
  desktop-click watcher (`DesktopPeek`), the Music connection (`MusicNowPlaying`) and the clock
  process (`ClockHelper`);
- the **wiring**: it subscribes to Music's published state and decides what the wallpaper shows,
  and it turns the gear's actions into Music commands.

It is created once in `main.swift` and lives until the process exits. Everything in it runs on
the main thread.

### Stored state

| Property | Type | Meaning |
|---|---|---|
| `statusItem` | `NSStatusItem!` | The menu-bar item; created in `applicationDidFinishLaunching`, hence implicitly unwrapped. |
| `wallpaper` | `WallpaperManager` (let) | All wallpaper windows, the player, scenes, gear and catchers. Created with the delegate. |
| `monitor` | `PlaybackMonitor` (let) | Play / pause decision and its human-readable reason. |
| `peek` | `DesktopPeek` (let) | Click-the-desktop-to-hide-files watcher. |
| `music` | `MusicNowPlaying` (let) | Music app state (`@Published`) and commands. |
| `musicWatch` | `AnyCancellable?` | Combine subscription to six of `music`'s publishers; calls `applyMusicWallpaper`. |
| `positionWatch` | `AnyCancellable?` | Subscription to `music.$position`; updates the gear and keeps YouTube in step. |
| `pausedSince` | `Date?` | When Music last stopped reporting "playing" while music was on the wallpaper; `nil` while playing. |
| `clockHotKey` | `HotKey?` | ⌃⌥⌘C, show / hide the clock; `nil` if registration failed. |
| `repairTimer` | `Timer?` | Every 6 h, `MovingLockScreen.repair()`; only while Moving Lock Screen is on. |
| `filesHotKey` | `HotKey?` | ⌃⌥⌘D, hide / show desktop files. |
| `recentSongs` | `[String]` | Up to 50 `name|artist` keys, to tell Previous from Next. |
| `pauseGrace` | `DispatchWorkItem?` | The pending re-check 3.1 s after a pause began. |
| `pauseGraceSeconds` | `static let TimeInterval = 3` | How long a "not playing" report may last before the wallpaper drops the music. |
| `settings` | `Settings` (let) | `Himawari.Settings.shared` (the wallpaper domain). |
| `clock` | `ClockHelper` (let) | Starts / stops the clock helper app. |
| `deck` | `MusicNowPlaying.Deck?` | Music's volume, repeat, shuffle, BASS / TREBLE and equalizer state as last read, then edited locally as the user turns knobs. |
| `deckTimer` | `Timer?` | Every 3 s (tolerance 1 s), re-read the deck while the gear is on screen. |
| `lastGearTouch` | `CFTimeInterval` | `CACurrentMediaTime()` of the last knob movement; deck reads are ignored for 1.5 s after it. |
| `lastToneSent` | `CFTimeInterval` | When the last tone script was sent (throttle). |
| `finalTone` | `DispatchWorkItem?` | The delayed "final value" tone script. |

A local variable, `lastVolumeSent` (`AppDelegate.swift:92`), is captured by the gear's `perform`
closure and lives as long as that closure; it throttles volume scripts.

### applicationWillTerminate(_:) (lines 35–37)

Calls `clock.stop()`, which sets `ClockHelper.stopping` and sends SIGTERM to the clock process
(`Process.terminate()`), so the clock does not get restarted by `ClockHelper.ended()` and goes away
with the app. Nothing else is undone on quit, deliberately: the lock-screen picture and swapped
Aerials stay in place (they are meant to persist), the MediaRemote helper exits by itself when its
stdin closes, and the private Core Audio tap and aggregate device are destroyed with the process.
A force-quit or crash skips this method; the clock then notices within about 3 s through its
parent-pid check.

### applicationDidFinishLaunching(_:) (lines 39–165)

The launch sequence. AppKit calls it once, after the run loop has started. In order:

| Lines | Step | Why / detail |
|---|---|---|
| 40 | `clock.start()` | Retires the old launchd clock if its plist exists (this runs `launchctl bootout` synchronously, once), then launches `Desktop Clock.app`'s executable with `--parent <pid>`. Started first so the clock is up by the time the wallpaper can answer its tone request. |
| 41–44 | Status item | `NSStatusBar.system.statusItem(withLength: .squareLength)`; an empty `NSMenu` with `self` as delegate is attached. The menu is filled in `menuNeedsUpdate` each time it opens, so checkmarks always reflect current state. No image is set yet; the first `monitor.onChange` sets it a few lines later. |
| 45 | `NSApp.mainMenu = Self.appMenu()` | An app menu (About, Quit) that appears only while Himawari is a regular, active Dock app. |
| 46 | `applyDockVisibility()` | Switch to `.regular` if "Show in Dock" is on. |
| 48 | `wallpaper.setVolume(settings.volume, muted: settings.muted)` | Before anything is loaded, so the first `start` already knows whether to build the picture-only (audio-stripped) item. |
| 49–58 | Restore the user's video | Only if `videoPath` is set *and the file still exists*. `wallpaper.load(url:)`; if "Lock Screen (Still)" is on and none of Himawari's frames is the current desktop picture (`LockScreen.isShowing`), make one; if Moving Lock Screen is on, `adopt` (record a hand-made swap as Himawari's), then `apply(video:)` and `startRepairTimer()`. |
| 59–64 | `monitor.onChange` | On every decision (at least every 2 s): pass "can the desktop be seen" to the wallpaper (`setDesktopVisible`, which drives the gear and CD animations), play or pause the video (`setPlaying`), and redraw the status icon bright only if playing and there is something to play. |
| 65 | `monitor.start()` | Registers for screen sleep / wake and lock / unlock notifications, starts the 2 s timer, and evaluates once immediately, which sets the status icon. |
| 66–75 | Global hotkeys | `HotKey(keyCode: kVK_ANSI_C, modifiers: cmdKey \| optionKey \| controlKey, id: 7)` → `toggleDesktopClock`; `kVK_ANSI_D`, id 8 → `toggleDesktopFiles`. If registration fails, a log line says to use the menu instead. |
| 77–81 | Desktop clicks | `peek.onChange` → `wallpaper.setClear(clear)`; a click on the raised wallpaper itself (`wallpaper.onClearedClick`, from the canvas's `mouseDown`) or one seen by `peek`'s local monitor (`onWallpaperClick`) → `setClear(false)`; finally `peek.enabled` from the setting, which installs the monitors. |
| 85–86 | Music options | `music.youtubeFallback` only when both music options are on; `music.tracksPosition = false` stops `MusicNowPlaying`'s 1 s tick until something needs the position. |
| 87–90 | `PowerState.onChange` | When Battery Saver turns on or off: `wallpaper.powerChanged()` (re-pick stream size, swap blurred fill for soft colours, slow tone sampling, quiet animations), then `applyMusicWallpaper()` (YouTube is skipped in Battery Saver; also re-evaluates pausing). |
| 92–131 | Gear wiring | See "Gear actions" below. |
| 133–140 | `deckTimer` | Every 3 s, if the gear is on screen (`wallpaper.gearActive`) and no knob was touched in the last 1.5 s, `refreshDeck()`. REPEAT and SHUFFLE can be changed in Music itself; this is how the lamps follow. |
| 143 | `WallpaperTone.onReadingRequest` | The clock's "what's behind me?" requests go to `wallpaper.clockMoved(to:)`. |
| 144–149 | `musicWatch` | See "The Music subscription" below. |
| 151–160 | `positionWatch` | Each new position: `updateSong()` (the gear's time and progress), and if a YouTube loop is showing, `syncYouTube(to:songPlaying:)`. |
| 162–164 | First run | If there is still nothing to play (no saved video, or the file is gone), open the "Choose Video…" panel straight away. |

#### The Music subscription

```swift
musicWatch = Publishers.CombineLatest4(music.$motionVideo, music.$isPlaying, music.$youtubeVideos, music.$artwork)
    .combineLatest(music.$searching, music.$track)
    .receive(on: RunLoop.main)
    .sink { [weak self] _ in
        onMainActor { self?.applyMusicWallpaper() }
    }
```
(`AppDelegate.swift:144-149`)

Combine's `CombineLatest4` can merge at most four publishers, so the remaining two are merged with
a second `combineLatest`. The values themselves are ignored: `applyMusicWallpaper` reads the
current properties of `music` directly. That makes `.receive(on: RunLoop.main)` essential even
though everything is already on the main thread. An `@Published` property emits in its `willSet`,
*before* the stored value changes; without the hop, the sink would read the old values. Scheduling
on the run loop delivers the event on a later pass, after the assignment has completed.

`@Published` also emits on every assignment, not only on changes, and `MusicNowPlaying` assigns
`isPlaying` on every status reading (each MediaRemote message, including its 5 s heartbeat, and
each AppleScript refresh). So `applyMusicWallpaper` runs at least every few seconds while Music is
running. That is affordable because every `WallpaperManager` setter it calls returns early when
nothing changed (`setOverride`, `setYouTube`, `setScene`, `setSong` each start with an equality
guard).

The weak capture plus `onMainActor` is the pattern used for every callback in this file: the
subscription is owned by the delegate, so a strong capture would be a retain cycle (harmless for a
process-lifetime object, but avoided consistently).

#### Gear actions (lines 92–131)

Three closures are installed on `wallpaper.gearControls`:

- `song` returns `(songPosition(), track.duration)` or `nil` when nothing plays. `GearControls`
  uses it to keep scrubs inside the song.
- `volumeNow` asks Music for its current volume (`fetchVolume`, an `osascript` round trip) when a
  VOLUME knob is grabbed, defaulting to 50 if Music does not answer, and reports it as 0…1.
  `GearControls` starts the drag from the value the knob already shows and ignores this answer
  if the drag has begun by the time it arrives, so the knob does not jump under the pointer.
- `perform` maps each `GearControls.Action` to a Music command:

| Action | Command | Notes |
|---|---|---|
| `.button(.previous)` | `music.previous()` | AppleScript `previous track` |
| `.button(.playPause)` | `music.playPause()` | `playpause` |
| `.button(.next)` | `music.next()` | `next track` |
| `.button(.stop)` | `music.pause()` | STOP pauses (stopping would drop the track and the gear with it) |
| `.button(.eject)` | `music.openMusic()` | brings the Music app up via `NSWorkspace.openApplication` |
| `.button(.repeatMode)` | toggle `deck.repeating`, `wallpaper.showDeck(deck)`, `music.setRepeat` | `set song repeat to all/off`; the lamp changes before Music confirms |
| `.button(.shuffle)` | toggle `deck.shuffling`, show, `music.setShuffle` | `set shuffle enabled to true/false` |
| `.button` (any other) | nothing | `.progress`, `.jog`, `.volume`, `.bass`, `.treble` are `GearControl` cases that never arrive as buttons |
| `.seek(fraction)` | `music.seek(to: fraction * duration)` | a click on the progress ladder |
| `.scrub(seconds)` | `music.seek(to: max(0, songPosition() + seconds))` | jog wheel or disc released |
| `.volume(v, done)` | `music.setVolume(Int(v*100))` at most every 0.1 s, and always when `done`; `deck.volume = v` | sets `lastGearTouch` so a deck read does not jump the knob; `GearControls` sends nothing for a click without a drag |
| `.tone(bass, treble, done)` | `setTone(bass:treble:done:)` | see below; sent only while dragging, on release after a drag, and on double-click (flat) |

Every Music command ends with `MusicNowPlaying.refresh()` once the script completes, so the
displayed state catches up with what Music actually did.

### applyMusicWallpaper() (lines 168–213)

The decision function: given Music's state and the settings, what should the wallpaper show? It is
called by the Combine subscription, by the pause-grace timer, by both music menu toggles and by
`PowerState` changes.

```
                 ┌───────────── isPlaying ─────────────┐
                 │ pausedSince = nil, cancel grace      │
    ┌────────────┴───────┐                     not playing, music on wallpaper, pausedSince == nil
    │      PLAYING        │ ───────────────▶   pausedSince = now; re-check in 3.1 s
    └────────────┬───────┘                              │
                 ▲                                        ▼
                 │ isPlaying                  ┌────────────────────────┐
                 └────────────────────────────│  GRACE (< 3 s): still   │
                                              │  counts as playing      │
                                              └───────────┬────────────┘
                                                          │ ≥ 3 s, re-check fires
                                                          ▼
                                              ┌────────────────────────┐
                                              │  OFF: user's own video │
                                              └────────────────────────┘
```

Step by step:

1. **Pause grace** (lines 172–182). Skipping a song makes Music report "not playing" briefly,
   sometimes several times as the notification, MediaRemote and AppleScript sources catch up.
   Treating each such report as a pause would tear down the CD scene and rebuild it instead of
   changing discs. So when Music reports playing, `pausedSince` is cleared and any pending
   re-check cancelled. When it reports not playing, music is on the wallpaper, and no pause is
   being timed yet, `pausedSince` is set and a `DispatchWorkItem` is scheduled 3.1 s later to call
   this function again. The extra 0.1 s makes sure the re-check lands after the 3 s window has
   closed.
2. **Direction** (line 183): `noteDirection()` records whether this is a new song or a return to
   the previous one.
3. **On?** (lines 184–186): `playingOrSkipping` is true while playing or within 3 s of the pause
   starting; `on` additionally requires the "Use Apple Music Artwork While Playing" setting.
4. **Between songs** (lines 189–192): if `on`, the new song is still being looked up
   (`music.searching`) and something from the music is already on screen, only the side-gear text
   is updated and the function returns. The previous animation or CD stays until the new one is
   known, so there is no flash of the user's own video between songs.
5. **Motion artwork** (line 193): `wallpaper.setOverride(on ? music.motionVideo : nil)`. `nil`
   puts the user's video back.
6. **YouTube** (lines 195–196): only if `on`, there is no motion artwork, the YouTube option is on
   and Battery Saver is off (a full-screen web player costs real battery); otherwise `nil`.
7. **Song info** (line 197): `updateSong()` before the scene, because `setScene` compares the
   current song with the one on the disc to decide whether a new cover is a sharper copy of the
   same cover (repaint in place) or a new song (change discs).
8. **CD scene** (lines 201–206): wanted when `on` and neither an animation nor YouTube is
   available. The cover used is the current artwork when the lookup has finished, or (if a CD is
   already showing) whatever artwork is known, possibly `nil`. The final condition skips
   `setScene(nil)` when a CD is showing and wanted but the new cover is not known yet, so the old
   disc stays rather than the scene being removed.
9. `updateSong()` again (line 207), cheap because `setSong` ignores equal values.
10. **Position tracking** (line 210): `music.tracksPosition` is turned on only when something
    displays the position: a YouTube loop, or the gear next to motion artwork or on the CD scene.
    Otherwise the 1 s tick in `MusicNowPlaying` is stopped.
11. If YouTube is showing, sync it to the current position (line 211).
12. `monitor.evaluate()` (line 212): what is shown affects pausing and the status text.

### songPosition() (lines 216–218)

`music.measuredPosition + (isPlaying ? CACurrentMediaTime() - music.measuredAt : 0)`. Music's
last reading carried forward on the monotonic media clock. `measuredAt` is set from the
MediaRemote timestamp (corrected for the message's age) or from the midpoint of an AppleScript
call. The result is not clamped to the song's duration; `GearControls.clamped` does that where it
matters.

### refreshDeck() (lines 220–226)

Calls `music.fetchDeck`, one AppleScript that returns volume, repeat, shuffle, the BASS and
TREBLE bands of the "Himawari" preset (0 unless that preset is current and the equalizer is on),
whether the equalizer is on and the current preset's name. If a reading arrives and no knob has
been touched for 1.5 s, it becomes `deck` and is shown on every gear (`wallpaper.showDeck`). The
second check is needed because the script runs asynchronously: a reading taken just before the
user grabbed a knob would otherwise snap the knob back.

### setTone(bass:treble:done:) (lines 230–255)

The BASS and TREBLE knobs shape Himawari's own equalizer preset in Music (chapter on the music
pipeline describes the AppleScript). This method handles state and timing:

1. Marks the gear as touched.
2. **Remember what to restore** (lines 233–237). If the current deck shows that the user's own
   equalizer is in effect (a preset other than "Himawari", or the equalizer off), its on/off state
   and preset name are saved in `UserDefaults.standard` as `toneRestoreOn` and
   `toneRestorePreset`. Saving to defaults (not just memory) means the restore point survives
   restarts; it is captured only while Himawari's preset is not yet active, so it is never
   overwritten with Himawari's own preset.
3. Updates the local `deck` to what is about to be true (Himawari preset, equalizer on, new dB
   values).
4. Builds `send`, which records the time and calls `music.setTone(bass:treble:restore:)`. When
   both values are within ±0.25 dB of zero, `setTone` puts the saved preset back (or "Flat") and
   restores the equalizer's on/off state instead of shaping the preset.
5. **Timing** (lines 247–254). Any pending final send is cancelled. While dragging, a script is
   sent at most every 0.25 s. On release (`done`), the final values are sent 0.3 s later. Each
   script runs in its own `osascript` process on a concurrent queue, so two scripts sent close
   together can finish in either order; delaying the last one makes it very likely to be applied
   last.

### noteDirection() (lines 259–272)

Music does not say whether a track change came from Next or Previous, but the CD scene should slide
the right way. The method keeps a history of `name|artist` keys. If the current song is the last
entry, nothing changed. If it is the second-to-last, the user went back: the last entry is
removed and `wallpaper.discDirection = .backward`. Otherwise the song is appended (the history is
capped at 50 by dropping the oldest) and the direction is `.forward`. Each new song also triggers
`refreshDeck()`, so REPEAT / SHUFFLE / volume are fresh when the gear appears.

```
history [A, B]   now A → backward, history [A]
history [A]      now B → forward,  history [A, B]
history [A, B]   now C → forward,  history [A, B, C]
```

A song played twice in a row (repeat one) produces no change, which is correct: there is no disc
change to animate.

### updateSong() (lines 274–279)

Maps `music.track` to a `SongInfo` (title, artist, album, duration, measured position, playing,
`measuredAt`) and passes it, or `nil`, to `wallpaper.setSong`, which feeds the side gear and the
CD scene and starts or stops the audio meters.

### Menu-bar icon (lines 283–308)

`updateStatusIcon(playing:)` sets the status button's image to `sunflowerIcon(bright:)` and its
tooltip to "Himawari — <monitor.reason>". It runs on every `PlaybackMonitor` decision, so at least
every 2 s.

`sunflowerIcon(bright:)` draws an 18×18 point image with a drawing handler (`NSImage(size:flipped:
drawingHandler:)`, re-run at whatever scale the menu bar needs, so it is sharp on Retina): twelve
oval petals (2.7 × 4.9 points, starting 3.6 points from the centre) rotated in steps of 30° around
the centre, and a 6.6-point disc. The colour is black at full opacity when playing and 40% when
not. `isTemplate = true` tells AppKit to treat the image as a mask and tint it to match the menu
bar (dark on a light bar, light on a dark one, and highlighted when the menu is open), so only the
opacity carries meaning.

### Dock icon (lines 310–341)

| Method | What it does |
|---|---|
| `applyDockVisibility()` | `NSApp.setActivationPolicy(showInDock ? .regular : .accessory)`. `.regular` gives a Dock icon and lets the app own the menu bar when active; `.accessory` removes both. Called at launch and from the "Show in Dock" toggle; the change takes effect immediately. |
| `applicationDockMenu(_:)` | Right-click on the Dock icon: a fresh `NSMenu` built by `buildMenu(forDock: true)`. |
| `applicationShouldHandleReopen(_:hasVisibleWindows:)` | Left-click on the Dock icon of a running app: `statusItem.button?.performClick(nil)` opens the status item's menu under the menu-bar icon. Returns `false` so AppKit does not try to open a window. |
| `appMenu()` (static) | The main menu: one app menu with "About Himawari" (`orderFrontStandardAboutPanel`, which uses the bundle's name, version and icon) and "Quit Himawari" (⌘Q). Both have no explicit target, so they go up the responder chain to `NSApp`. It is visible only while Himawari is regular and frontmost. |

### menuNeedsUpdate(_:) and buildMenu(_:forDock:) (lines 345–421)

`menuNeedsUpdate` is the `NSMenuDelegate` callback AppKit sends just before the status menu opens;
it rebuilds the menu from scratch with `buildMenu(menu, forDock: false)`. Rebuilding is simpler than
keeping item states in sync, and the menu is small.

`buildMenu` removes all items and adds, in order:

| # | Item | Action | Key | State / enabled | Dock menu |
|---|---|---|---|---|---|
| 1 | "<reason> — <video file name>" or "No video chosen" | none | | disabled (status line) | yes |
| — | separator | | | | |
| 2 | Choose Video… | `chooseVideo` | ⌘O | | yes, no key |
| 3 | Pause / Resume (by `userPaused`) | `togglePause` | ⌘P | | yes, no key |
| — | separator | | | | |
| 4 | Mute | `toggleMute` | | ✓ if muted | yes |
| 5 | "Volume" label + slider | `volumeChanged(_:)` | | slider 0…1 | no (custom views are not allowed in Dock menus) |
| — | separator | | | | |
| 6 | Music Video Sizing ▸ four `VideoSizing` modes | `setSizing(_:)` | | ✓ current | yes |
| | ▸ separator, Fill Gaps With ▸ three `BarFill` modes | `setBarFill(_:)` | | ✓ current | yes |
| 7 | Use Apple Music Artwork While Playing | `toggleMusicWallpaper` | | ✓ | yes |
| 8 | "    …or a YouTube Loop of the Song" | `toggleMusicYouTube` | | ✓; disabled unless 7 is on | yes |
| 9 | Hide Desktop Files | `toggleDesktopFiles` | ⌃⌥⌘D | ✓ while cleared | yes |
| 10 | Click Desktop to Hide Files | `toggleClickToClear` | | ✓ | yes |
| 11 | Show Wallpaper on Lock Screen (Still) | `toggleLockScreen` | | ✓ | yes |
| 12 | Moving Lock Screen [(Preparing… n%)] | `toggleMovingLockScreen` | | ✓ | yes |
| 13 | Show Desktop Clock | `toggleDesktopClock` | ⌃⌥⌘C | ✓ from the shared clock setting | yes |
| 14 | Pause When Desktop Is Covered | `toggleCovered` | | ✓ | yes |
| 15 | Pause on Battery | `toggleBattery` | | ✓ | yes |
| 16 | Show in Dock | `toggleDock` | | ✓ | yes |
| 17 | Launch at Login | `toggleLaunchAtLogin` | | ✓ if `SMAppService.mainApp.status == .enabled` | yes |
| 18 | "Clock options: right-click the clock" | none | | disabled (hint) | yes |
| — | separator, Quit Himawari | `NSApplication.terminate(_:)`, target `NSApp` | ⌘Q | | no (the Dock adds its own Quit) |

Details worth knowing:

- The enum cases' raw values are their menu titles, and `representedObject` carries the raw value
  so `setSizing` / `setBarFill` can map the clicked item back to a case.
- The ⌃⌥⌘D and ⌃⌥⌘C key equivalents duplicate the global hotkeys. Inside an open menu they work
  as menu shortcuts; their main purpose is to show the user the global shortcut.
- The Moving Lock Screen title shows `MovingLockScreen.shared.status` ("Preparing… 42%") while a
  conversion runs. Because the menu is rebuilt only when it opens, the percentage is a snapshot;
  `MovingLockScreen.onStatus` exists for live updates but `AppDelegate` never sets it.
- "Launch at Login" reads its state from `SMAppService` each time rather than from a setting, so
  it also reflects changes made in System Settings ▸ General ▸ Login Items.
- The "Music Video Sizing" title is accurate: `WallpaperManager.effectiveSizing` applies the
  chosen sizing only to the music wallpaper; the user's own video always fills the screen.

`item(_:_:key:checked:)` (lines 423–428) creates an `NSMenuItem` with the action, key equivalent,
`target = self` (actions are private `@objc` methods of the delegate, which the responder chain
would not reach otherwise) and `.on` / `.off` state.

`volumeSliderItem()` (lines 430–439) puts an `NSSlider` (0…1, current volume, 180×22 at x 20)
inside a 220×30 container view and makes that the item's `view`. A menu item with a custom view
draws and handles that view itself; the slider's target-action sends `volumeChanged(_:)`. The code
does not set the slider's `isContinuous`, so how often it reports while dragging is AppKit's
default.

### Actions (lines 443–607)

#### chooseVideo() (lines 443–456)

Opens an `NSOpenPanel` titled "Choose a video for your wallpaper", restricted to
`UTType.movie` (which admits `.mp4`, `.mov`, `.m4v`; the comment notes AVFoundation cannot play
`.webm`), single selection. `NSApp.activate()` first, because an accessory app's panel would
otherwise open behind the frontmost app. `runModal()` blocks in a modal run loop until the user
answers. On OK: store `videoPath`, `wallpaper.load(url:)` (which starts it immediately unless
motion artwork is overriding), refresh the still lock-screen frame if that option is on, start a
Moving Lock Screen conversion for the new video if that option is on (the returned problem string
is ignored), and `monitor.evaluate()` so the play / pause state and icon update at once.

#### setBarFill(_:) and setSizing(_:) (lines 458–468)

Read the raw value from `representedObject`, convert it to the enum (ignoring unknown values),
save it in settings and push it to the wallpaper (`wallpaper.barFill`, `wallpaper.sizing`), whose
property observers re-arrange every canvas.

#### toggleMusicWallpaper() and toggleMusicYouTube() (lines 470–480)

Flip the setting, recompute `music.youtubeFallback` (YouTube is looked up only when both are on,
so no YouTube search is made otherwise), and re-decide with `applyMusicWallpaper()`. Turning the
music wallpaper off while a song plays immediately restores the user's video.

#### togglePause(), toggleMute(), volumeChanged(_:) (lines 482–498)

`togglePause` flips `userPaused` and re-evaluates; the monitor's first rule is "paused by hand",
which also changes the status line and the Pause / Resume title. `toggleMute` flips `muted` and
applies volume and mute. `volumeChanged` stores the slider's value, unmutes if the slider moved
above zero ("moving the slider means you want sound"), and applies. In
`WallpaperManager.setVolume`, a volume below 0.005 counts as muted and a change of muted state
restarts a local video so the picture-only (no audio track) version is used while silent.

#### toggleDesktopClock() (lines 502–505)

```swift
@objc private func toggleDesktopClock() {
    HimawariKit.Settings.shared.showClock.toggle()
    HimawariKit.Settings.broadcastChange()
}
```

The clock is another process, so Himawari does not show or hide it directly. It flips the shared
`showClock` setting in the `local.dhairyabhatia.desktop` domain and broadcasts a change; the clock
re-reads its settings and creates or removes its window (and shows a "Clock hidden — bring it back
with ⌃⌥⌘C" hint for a few seconds when hidden). The clock process keeps running while hidden. The
fully qualified `HimawariKit.Settings` is required because the unqualified name means the
wallpaper settings in this target.

#### toggleDesktopFiles() (lines 508–510)

`wallpaper.setClear(!wallpaper.cleared)`: raise the wallpaper windows above Finder's icons
(desktop-icon level + 1) and let them take clicks, or put them back (desktop level + 1,
click-through).

#### startRepairTimer() (lines 514–519)

Invalidates any existing timer, then schedules `MovingLockScreen.shared.repair()` every 6 hours.
macOS can re-download an Aerial at any time, replacing Himawari's file; `repair` compares each
swapped file's size with the recorded size and swaps again if it differs. Called at launch (when
the option is on) and after turning the option on.

#### toggleMovingLockScreen() (lines 521–560)

Turning **off**: clear the setting, stop the repair timer, `MovingLockScreen.shared.restore()`
(cancel a conversion in progress, move Apple's originals back, delete the master copy and the saved
state).

Turning **on**:

1. Requires a chosen video; with none, it returns silently.
2. An `NSAlert` explains what will happen: macOS only animates Aerials on the lock screen, so the
   picked Aerials' videos (and the screen saver's) are swapped for the user's; Apple's are kept;
   conversion takes about five times the Aerial's length, often 20–30 minutes, once per video, and
   keeps the processor busy; macOS may pause the lock screen on battery. Buttons "Turn On" /
   "Cancel"; `runModal()` blocks until answered.
3. `MovingLockScreen.shared.apply(video:)` returns a problem string when no downloaded Aerial is
   picked in System Settings. In that case a second alert ("Pick an Aerial first") offers "Open
   Wallpaper Settings", which opens
   `x-apple.systempreferences:com.apple.Wallpaper-Settings.extension`, and the setting stays off.
4. Otherwise the conversion has started in the background; the setting is turned on, the still
   lock-screen option is turned off ("the Aerial is the lock screen now"), and the repair timer is
   started.

#### toggleLockScreen() (lines 563–570)

Flips `lockScreenMatch`. On (with a video): `LockScreen.show(frameOf:)` remembers each screen's
current desktop picture (the first time only), takes a frame a quarter of the way into the video
at full screen resolution, writes it as a PNG under Application Support and sets it as every
screen's desktop picture. Off (or on without a video): `LockScreen.restore()` puts the remembered
pictures back and deletes the frames.

#### toggleClickToClear(), toggleCovered(), toggleBattery(), toggleDock() (lines 572–591)

`toggleClickToClear` flips the setting, sets `peek.enabled` (which adds or removes the global and
local mouse monitors), and, when turning it off, brings the files back in case they were hidden.
`toggleCovered` and `toggleBattery` flip their pause rules and re-evaluate. `toggleDock` flips
`showInDock` and applies the activation policy.

#### toggleLaunchAtLogin() (lines 593–607)

Uses `SMAppService.mainApp` (ServiceManagement, macOS 13+), which registers the app itself as a
login item without a separate helper or launchd plist. If it is enabled, `unregister()`;
otherwise `register()`. On error, an alert built from the `NSError` adds advice: move the app to
`/Applications` (registration of an app run from a build folder or a disk image can fail) and
check System Settings ▸ General ▸ Login Items, where the user may have to approve it. A status of
`.requiresApproval` is shown unchecked; choosing the item again calls `register()` again.

### Notes and risks

- `AppDelegate.swift:55`: at launch, `apply(video:)` silently starts a 20–30 minute conversion if
  the picked Aerials changed since the last run; with no Aerial picked, its problem string is
  ignored and the setting stays on with nothing applied.
- `AppDelegate.swift:454`: choosing a new video with Moving Lock Screen on starts a new
  conversion each time without any confirmation, and ignores the "pick an Aerial" problem.
- `AppDelegate.swift:529`: turning Moving Lock Screen on without a chosen video does nothing and
  shows nothing.
- `AppDelegate.swift:558`: turning Moving Lock Screen on clears `lockScreenMatch` without calling
  `LockScreen.restore()`, so the still frame stays as the desktop picture and the
  `lockScreenOriginalWallpapers` backup stays in defaults.
- `AppDelegate.swift:80` with `DesktopPeek.swift:30`: since commit 782c03a the local monitor
  ignores clicks in any `NSPanel` (to spare the gear's catchers), but the wallpaper windows are
  `NSPanel`s too (`WallpaperManager.swift:557`), so `onWallpaperClick` can no longer fire; bringing
  the files back by clicking the wallpaper now relies only on `wallpaper.onClearedClick` (the
  canvas's `mouseDown`, line 79), which still works.
- `AppDelegate.swift:108-113`: REPEAT and SHUFFLE do nothing (beyond the button's press
  animation) until a deck reading has succeeded, because they toggle `self.deck?`.
- `AppDelegate.swift:247-254`: tone scripts run as separate `osascript` processes on a concurrent
  queue; the 0.3 s delay before the final one makes ordering likely, not guaranteed.
- `AppDelegate.swift:59-64`: `wallpaper.setPlaying` and a fresh icon image are produced on every
  2-second evaluation even when nothing changed.
- `AppDelegate.swift:401`: `MovingLockScreen.onStatus` is never connected, so the progress in the
  menu does not update while the menu is open.
- `AppDelegate.swift:443-449`: `runModal()` (and the alerts' `runModal()`) block the main thread in
  a modal run loop; timers scheduled in the default mode (the 2 s monitor, the 3 s deck timer) do
  not fire while the panel is open.
- `AppDelegate.swift:233-237`: the restore point for the equalizer is captured only when a deck
  reading exists; on the first-ever knob turn without one, turning both knobs back to zero
  selects "Flat" and disables the equalizer rather than restoring the user's setup.

## Sources/Himawari/Settings.swift

120 lines. The wallpaper's settings: a thin typed wrapper around `UserDefaults.standard`, which
for this app is the preferences domain `local.dhairyabhatia.himawari`
(`~/Library/Preferences/local.dhairyabhatia.himawari.plist`, managed by `cfprefsd`). Used by
`AppDelegate`, `PlaybackMonitor` and `WallpaperManager`. It is not annotated with an actor;
`UserDefaults` is thread-safe and all callers are on the main thread anyway.

### class Settings

`final class Settings` with `static let shared` and a private initializer: a process-wide
singleton. Its only stored property is `defaults = UserDefaults.standard`.

`init()` (lines 9–24) registers defaults in the *registration domain*, an in-memory layer
consulted when a key has never been written. Nothing is saved by registering; the values below are
what a first run sees:

| Key | Registered default | Why |
|---|---|---|
| `volume` | 0.5 | |
| `muted` | true | "wallpapers are silent unless you ask" |
| `pauseOnBattery` | true | |
| `pauseWhenCovered` | true | |
| `userPaused` | false | |
| `showInDock` | false | |
| `musicWallpaper` | true | the music features are the point of the app |
| `musicYouTube` | false | the CD scene instead; YouTube is opt-in |
| `clickToClearDesktop` | true | |
| `lockScreenMatch` | false | it replaces the user's desktop picture: opt in |
| `movingLockScreen` | false | swaps system Aerials and converts for a long time: opt in |
| `videoSizing` | `VideoSizing.widescreen.rawValue` | |

Computed properties (each a getter and setter over one key):

| Property | Type | Key | Notes |
|---|---|---|---|
| `videoPath` | `String?` | `videoPath` | no default; `nil` until a video is chosen |
| `volume` | `Float` | `volume` | `float(forKey:)` |
| `muted` | `Bool` | `muted` | |
| `pauseOnBattery` | `Bool` | `pauseOnBattery` | |
| `pauseWhenCovered` | `Bool` | `pauseWhenCovered` | also gates the Battery Saver "mostly covered" pause |
| `userPaused` | `Bool` | `userPaused` | paused by hand; survives restarts |
| `musicWallpaper` | `Bool` | `musicWallpaper` | |
| `musicYouTube` | `Bool` | `musicYouTube` | |
| `lockScreenMatch` | `Bool` | `lockScreenMatch` | |
| `movingLockScreen` | `Bool` | `movingLockScreen` | |
| `clickToClearDesktop` | `Bool` | `clickToClearDesktop` | |
| `videoSizing` | `VideoSizing` | `videoSizing` | stored as the raw value; unknown strings fall back to `.widescreen` |
| `barFill` | `BarFill` | `barFill` | see below |
| `showInDock` | `Bool` | `showInDock` | |

`barFill` (lines 93–99) carries a migration in its getter: if `barFill` holds a valid raw value,
use it; otherwise fall back to the older boolean key `blurredBars` (true → `.blurred`, false or
missing → `.ambient`). The setter writes only the new key. The old key is never deleted, which is
harmless.

Other code in the target writes further keys to the same domain directly, without going through
this class: `lockScreenOriginalWallpapers` (`LockScreen`), `movingLockScreenState`
(`MovingLockScreen`), `toneRestoreOn` / `toneRestorePreset` (`AppDelegate.setTone`).

### enum BarFill and enum VideoSizing (lines 108–120)

| `BarFill` case | Raw value (menu title, stored value) | Meaning |
|---|---|---|
| `ambient` | "Soft Colors (Apple Music Style)" | slow glow in the video's own edge colours |
| `blurred` | "Blurred Video" | a blurred, enlarged copy of the video behind it (replaced by `ambient` in Battery Saver) |
| `black` | "Black Bars" | |

| `VideoSizing` case | Raw value | Meaning |
|---|---|---|
| `widescreen` | "Widescreen (Bars Top & Bottom)" | the whole video, never cropped, as large as fits below the menu-bar strip; square covers get bars at the sides |
| `fit` | "Show Whole Video" | nothing cropped, bars around it |
| `fitWidth` | "Fit Width" | full width; trims top and bottom if taller, bars if shorter |
| `fill` | "Fill Screen" | covers everything, cropping the overflow |

Both are `String`-backed and `CaseIterable` so the menu can list them and store them by raw value.

### Notes and risks

- `Settings.swift:108`: the doc comment "How the wallpaper video is sized to the screen" sits on
  `BarFill`; it describes `VideoSizing`.
- `Settings.swift:63`: the comment says the YouTube option loops "the middle of the song's YouTube
  video"; `YouTubeLoopView` plays the whole video and follows the song's position.
- `Settings.swift:109-120`: menu titles double as stored values; renaming a title silently resets
  users' stored choice to the default.
- `Settings.swift:5`: the type is named `Settings`, the same as `HimawariKit.Settings`; inside this
  target it shadows the kit's, which is easy to misread.

## Sources/HimawariKit/Settings.swift

198 lines. The settings shared by Himawari and the clock helper, and the mechanism by which a
change in one process reaches the other. In this repository the clock's own options are the only
keys that both processes actually use.

### class Settings

`public final class Settings`, singleton `public static let shared`.

| Member | Type | Meaning |
|---|---|---|
| `domain` | `static let String = "local.dhairyabhatia.desktop"` | the shared preferences domain |
| `changed` | `private static let Notification.Name` | `local.dhairyabhatia.desktop.changed` |
| `defaults` | `private let UserDefaults` | the store for `domain` |

#### init() (lines 15–30)

```swift
private init() {
    // The wallpaper app's own domain IS the shared one; the services open it as a suite.
    defaults = Bundle.main.bundleIdentifier == Self.domain ? .standard : UserDefaults(suiteName: Self.domain)!
```

A process whose bundle id *is* the domain uses `.standard`; every other process opens the domain
as a suite. The distinction exists because `UserDefaults(suiteName:)` returns `nil` when given the
calling app's own bundle identifier, which would crash the force unwrap. Neither current process
has that bundle id (Himawari is `…himawari`, the clock is `…desktop.clock`), so both take the suite
path; the comment dates from an earlier layout. A suite reads and writes
`~/Library/Preferences/local.dhairyabhatia.desktop.plist` through `cfprefsd`, which serves all
processes of the user, so both see the same values.

Registered defaults: `volume` 0.5, `muted` true, `pauseOnBattery` true, `pauseWhenCovered` true,
`userPaused` false, `showInDock` false, `showClock` true, `clockPosition` "Top Center", `clock24h`
false, `clockSeconds` false. Registration is per process, so each process registers its own copy.

#### broadcastChange() (lines 35–38)

Posts `local.dhairyabhatia.desktop.changed` on `DistributedNotificationCenter.default()` with
`deliverImmediately: true`. Distributed notifications go through a system daemon to every process
of the user that observes the name; `deliverImmediately` asks that they be delivered even to
processes that are suspended or in the background instead of being queued. The notification
carries no payload: receivers re-read the defaults.

#### onChange(_:) (lines 42–53)

```swift
@MainActor
public static func onChange(_ block: @escaping @MainActor () -> Void) {
    let debounce = Debounce()
    DistributedNotificationCenter.default().addObserver(forName: changed, object: nil, queue: .main) { _ in
        onMainActor {
            debounce.pending?.cancel()
            let work = DispatchWorkItem { onMainActor { block() } }
            debounce.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }
}
```

Each registration gets its own `Debounce` box. Each notification cancels the pending call and
schedules a new one 0.15 s later, so a burst of changes (a picker that writes two keys, two
processes broadcasting) produces one call after the burst. Observers are delivered on the main
queue; the observer token is discarded, so the registration lasts for the process's life. Only the
clock calls it (`HimawariClock/main.swift:9`).

#### Raw access (lines 57–77)

| Method | Does |
|---|---|
| `string(_:)` | `synchronize()`, then `string(forKey:)` |
| `set(_:for:)` | `set(_:forKey:)` (no broadcast; callers broadcast) |
| `stringArray(_:)` | `synchronize()`, then `stringArray(forKey:)`; unused here |
| `counts(_:)` | `synchronize()`, then the value as `[String: Int]` or `[:]`; unused here |
| `bool(_:)` (private) | `synchronize()`, then `bool(forKey:)` |

The intent, per the comment, is to "pick up what another process just wrote". On current macOS
`synchronize()` is documented as unnecessary (`cfprefsd` keeps processes coherent), so these calls
are harmless overhead on every read.

#### Properties

Wallpaper group (lines 81–115): `videoPath`, `volume`, `muted`, `pauseOnBattery`,
`pauseWhenCovered`, `userPaused`, `showInDock`. They mirror `Himawari.Settings` but in the shared
domain. Nothing in this repository reads or writes them; the Himawari target uses its own
`Settings` for these.

Clock group (lines 119–164):

| Property | Type | Behaviour |
|---|---|---|
| `showClock` | `Bool` | toggled by Himawari's menu and hotkey, and by the clock's "Hide Clock" item |
| `clockPosition` | `ClockPosition` | raw-value string; unknown → `.topCenter` |
| `clock24h` | `Bool` | setter also writes `clockFormat` (24-Hour or 12-Hour) |
| `clockFormat` | `ClockFormat` | getter falls back to `clock24h` when `clockFormat` is missing (older settings); setter also updates `clock24h` when the format is 12- or 24-hour |
| `clockShowDate` | `Bool` | true when the key was never written (it has no registered default) |
| `clockSize` | `ClockSize` | unknown → `.medium` |
| `clockStyle` | `ClockStyle` | unknown → `.aero` |
| `clockSeconds` | `Bool` | |

The two-way coupling of `clock24h` and `clockFormat` keeps an older boolean and the newer
five-way format consistent, so either can be read.

### class Debounce (lines 168–171)

`private final class Debounce: @unchecked Sendable` holding `pending: DispatchWorkItem?`. A
reference type is needed so the observer closure can mutate shared state; `@unchecked Sendable`
silences the compiler about capturing it in a `@Sendable` notification block, justified by the
comment "Only ever touched on the main thread".

### Enums (lines 173–198)

| Enum | Cases (raw value) | Extras |
|---|---|---|
| `ClockFormat` | `twelve` "12-Hour", `twentyFour` "24-Hour", `beats` "Swatch Internet Time", `decimal` "French Decimal Time", `words` "In Words" | `next`: the following case, wrapping around (left-click on the clock) |
| `ClockSize` | `small`, `medium`, `large` | `scale`: 0.65, 1, 1.35 |
| `ClockStyle` | `aero` "Aero Glass", `vfd` "Fluorescent Display", `rounded`, `serif` | |
| `ClockPosition` | Top Left, Top Center, Top Right, Center, Bottom Left, Bottom Right | |

### Notes and risks

- `Settings.swift:16`: stale comment; neither process uses `.standard` for this domain.
- `Settings.swift:81-115`: the wallpaper properties and their registered defaults (lines 19–24) are
  unused duplicates of `Himawari.Settings`; a reader may think the wallpaper settings are shared.
- `Settings.swift:82,87`: `videoPath` and `volume` read without `synchronize()` while the others
  synchronize, an inconsistency (practically irrelevant, see above).
- `Settings.swift:17`: the force unwrap is safe only as long as no process's bundle id equals the
  domain without taking the first branch; the guard covers that case exactly.
- `Settings.swift:45`: the observer is never removed; calling `onChange` twice installs two
  observers (not done today).

## Sources/Himawari/Log.swift

25 lines. Himawari's diagnostic log at `~/Library/Logs/Himawari.log`, readable in Console.app or
with `tail -f`. Called 22 times from nine files (sizing decisions, audio meter state, clock helper
problems, lock screen, Moving Lock Screen progress, hotkey conflicts, desktop clicks).

`@MainActor enum Log` (an enum with no cases, used as a namespace) with one stored static,
`lastLine`, and one method.

### write(_:) (lines 8–23)

1. **De-duplicate** (lines 9–10): if the line equals the previous one, return. Only *consecutive*
   repeats are dropped, which suits callers like `VideoCanvas.arrange()` that log the same sizing
   line on every layout pass.
2. **Path** (line 11): `~/Library/Logs/Himawari.log`, recomputed on each call.
3. **Trim** (lines 13–16): if the file is larger than 1,000,000 bytes, read it all and write back
   the last half (`data.suffix(size / 2)`), so the log stays between 0.5 and 1 MB.
4. **Format** (line 17): the time only, in the user's locale (`formatted(date: .omitted, time:
   .standard)`), two spaces, the text, a newline.
5. **Append** (lines 18–22): open with `FileHandle(forWritingTo:)`, seek to the end, write, close.
   If the file does not exist, opening fails and the text is written as a new file instead.

The design is the simplest that works for an app that logs a few lines a minute: synchronous,
main-thread, no buffering. `os_log` / `Logger` was not used, so the log is a plain file a user can
attach to a report.

### Notes and risks

- `Log.swift:19`: `seekToEndOfFile()` and `write(_: Data)` are the older `FileHandle` APIs that
  raise an Objective-C exception on I/O errors (disk full, file removed), which Swift cannot catch;
  the throwing `seekToEnd()` / `write(contentsOf:)` would not crash.
- `Log.swift:15`: the cut can fall in the middle of a line or of a multi-byte UTF-8 character; the
  first line after a trim may be garbled.
- `Log.swift:17`: lines carry no date, so a log spanning several days cannot be ordered by
  timestamp alone.
- `Log.swift:13`: every write stats the file; trimming reads and rewrites up to 1 MB on the main
  thread (rare).

## Sources/HimawariKit/MainThread.swift

13 lines; one public generic function, called 45 times across the three targets.

```swift
public func onMainActor<T>(_ body: @MainActor () throws -> T) rethrows -> T {
    precondition(Thread.isMainThread, "onMainActor called off the main thread")
    return try withoutActuallyEscaping(body) { fn in
        try unsafeBitCast(fn, to: (() throws -> T).self)()
    }
}
```
(`MainThread.swift:8-13`)

**What it is for.** Swift's concurrency checker only allows `@MainActor` code to be called
synchronously from code it knows is on the main actor. Many AppKit and Foundation callbacks run on
the main thread without the compiler knowing: `Timer` blocks, `NotificationCenter` observers
registered with `queue: .main`, `NSEvent` monitors, `DispatchQueue.main.async` blocks, Carbon
hotkey handlers. The standard bridge is `MainActor.assumeIsolated { … }`, which checks at run time
that the current executor is the main actor and then runs the block. The file's comment records
that this check crashed Himawari (a SIGSEGV inside `swift_task_isMainExecutor`) when called from
plain main-thread timers. `onMainActor` replaces the executor check with a thread check.

**How it works.**

1. `precondition(Thread.isMainThread, …)` traps if called from any other thread. `precondition`
   stays active in release builds (only `-Ounchecked` removes it), so a misuse fails loudly
   instead of racing.
2. `body` is a non-escaping closure parameter. `unsafeBitCast` needs a value it can reinterpret,
   and a non-escaping closure cannot be stored or cast; `withoutActuallyEscaping` lends an
   escapable copy that is valid only inside its block (and checks at run time that it did
   not in fact escape).
3. `unsafeBitCast(fn, to: (() throws -> T).self)` reinterprets the `@MainActor` function as a plain
   function. Global-actor isolation is a type-checking attribute; it does not change the function's
   representation or calling convention for a synchronous closure, so the cast is a no-op at run
   time.
4. The result is called and returned; `rethrows` means a non-throwing `body` makes the call
   non-throwing.

The function is generic so it can return values (`onMainActor { … }` in `main.swift` returns
`Void`, `runBackgroundService` uses it around its whole body).

**Trade-offs.** The thread check is weaker than an executor check in one theoretical respect (code
on the main thread but inside another actor's synchronous context), which cannot occur in this
codebase's callbacks. It relies on an implementation detail of the ABI (that `@MainActor` and
nonisolated synchronous function types share a representation); this has been stable, but it is
exactly the kind of thing a future Swift could diagnose or change. In Swift 6 language mode the
cast would compile but sidestep the checker by design.

### Notes and risks

- `MainThread.swift:11`: `unsafeBitCast` between function types depends on actor isolation not
  affecting the representation; if a future compiler changes that, every callback site breaks at
  once.
- The crash it works around is described only in the comment; there is no reference to a Swift
  issue or OS version, so it is hard to know when `MainActor.assumeIsolated` could be used again.
