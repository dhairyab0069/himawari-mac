# 7 · The side gear, its controls and the audio meters

When the wallpaper shows something square (Apple Music's animated artwork, or the spinning CD of `MusicScene`), the screen has two empty bars, one on each side. Himawari fills them with two pieces of imitation 1980s hi-fi gear: a **CD deck** on the left and a **stereo level analyzer** on the right. The deck shows the song's title, artist, album, elapsed and remaining time and a segmented progress bar on a cyan "vacuum-fluorescent" display, with transport buttons and a jog wheel below. The analyzer has two analog VU meters, a ten-band spectrum display and three knobs.

The gear is more than decoration in two ways:

1. **It is playable.** The wallpaper window sits below Finder's desktop icons, so it never receives a click. `GearControls` places small, almost invisible panels *above* the icons, one per control, and turns clicks and drags into Music commands: play/pause, next, seeking, scrubbing with the jog wheel or by turning the CD by hand, volume, bass and treble.
2. **It can listen.** `AudioLevels` uses a Core Audio *process tap* (macOS 14.2+) to measure what Music is actually playing. The VU needles and spectrum then follow the real signal. `AudioPermission` checks and requests the privacy permission the tap needs. When the tap is unavailable or silent, the gear animates itself with randomised keyframe animations so it never looks frozen.

This chapter covers four files:

| File | Lines | Role |
|---|---|---|
| `Sources/Himawari/NowPlayingSides.swift` | 924 | The view that draws and animates both pieces of gear; also `SongInfo` and `GearControl` |
| `Sources/Himawari/GearControls.swift` | 329 | Click-catcher panels, gesture handling, the synthesized scratch sound |
| `Sources/Himawari/AudioLevels.swift` | 271 | Core Audio process tap, RMS and FFT band analysis |
| `Sources/Himawari/AudioPermission.swift` | 43 | TCC preflight / request for "System Audio Recording Only" |

The overall data flow:

```
        Music.app (AppleScript / MediaRemote, ch. on AppDelegate)        Music.app's audio
                     │ SongInfo, Deck (volume, EQ, repeat…)                   │
                     ▼                                                        ▼
          WallpaperManager.setSong / showDeck                   AudioLevels (process tap → aggregate
                     │                                            device → IO block on `queue`)
       ┌─────────────┴──────────────┐                                         │ Snapshot (RMS, bands)
       ▼                            ▼                                         │  via read(), 30 Hz
  VideoCanvas.setSong        MusicScene.setSong                               │
       └──────────► NowPlayingSides.show(info) ◄── meterSource ───────────────┘
                     │ controlRects (view coords)
                     ▼
          GearControls.update (screen rects) ──► Catcher panels (level desktop+22)
                     │  onDown / onDrag / onUp / onDoubleClick
                     ▼
          GearControls.perform(Action) ──► AppDelegate ──► Music commands
                     └─► NowPlayingSides.press / scrub / endScrub / volume / bass / treble
```

The project's deployment target is macOS 14.4 (`Package.swift:8`), which is why the file can use `CATapDescription` and `AudioHardwareCreateProcessTap` without availability checks.

---

## Sources/Himawari/NowPlayingSides.swift

### Purpose and place in the app

`NowPlayingSides` is an `NSView` that covers the whole wallpaper window and draws the gear in the bars left and right of a given "video" rectangle. It is owned by one of two hosts:

- `VideoCanvas` (`VideoCanvas.swift:19`, created lazily in `setSong` at line 35) when the wallpaper plays Apple Music's motion artwork. The host sets `autoresizingMask = [.width, .height]` and forwards `lively`, `meterSource`, `animating` and the song.
- `MusicScene` (`MusicScene.swift:30`) when the wallpaper shows the CD. The scene calls `place(around: discRect)` from its layout (`MusicScene.swift:445`).

`WallpaperManager` collects every visible gear view (`WallpaperManager.swift:336`) to push Music's deck state (`showDeck`, line 339, which sets `volume`, `bass`, `treble`, `repeating`, `shuffling`) and to hand the views to `GearControls.update`. Both hosts expose the view as `gear` for that purpose.

The file also defines the value type `SongInfo` (what the panels show), the two layout structs `DeckLayout` and `AnalyzerLayout`, the drawing namespace `Hardware`, and the public enum `GearControl` which names every clickable control and is shared with `GearControls`.

### Design decisions

- **Draw once, animate little.** The faceplates (brushed aluminium, screws, labels, VU faces, knobs, buttons) are rendered once into a `CGImage` per faceplate and set as `CALayer.contents`. Only small layers move: text layers on the display, the needles, the spectrum column masks, the jog wheel, the knob pointers and the play LED. A wallpaper is on screen all day, so the expensive part (Core Graphics drawing) happens only when the layout changes.
- **Core Animation does the motion.** In self-animated mode the needles, spectrum and jog wheel run as repeating `CAKeyframeAnimation` / `CABasicAnimation`s that the render server plays without waking the app. Each sets `preferredFrameRateRange` to 10–30 fps rather than the display's 60/120 Hz, saving GPU time. The app's own code only updates the clock digits once per second, timed to the second boundary.
- **Live mode is a 30 Hz timer.** When real levels are available, a `Timer` at 1/30 s reads a snapshot from `AudioLevels` and sets transforms directly with implicit animations disabled. VU ballistics (fast attack, slower release) are computed in code.
- **Coordinates are y-up.** All layouts are in faceplate coordinates with the origin bottom-left, matching AppKit's default unflipped view and `CALayer` in a layer-backed `NSView`. `controlRects` is in the view's coordinates so `GearControls` can convert it to screen coordinates.
- **No hit-testing.** `hitTest(_:)` returns `nil` (line 98), so the view never takes a click; interaction is done entirely by separate windows (see `GearControls`).

### `SongInfo` (lines 6–15)

A plain `Equatable` value describing the song for the panels.

| Property | Type | Meaning |
|---|---|---|
| `title` | `String` | Song name |
| `artist` | `String` | Artist |
| `album` | `String` | Album |
| `duration` | `Double` | Length in seconds (0 if unknown) |
| `position` | `Double` | Playback position in seconds when measured |
| `playing` | `Bool` | Whether Music is playing |
| `measuredAt` | `Double` | `CACurrentMediaTime()` when `position` was true; defaults to "now" |

`CACurrentMediaTime()` is the Core Animation clock: seconds since boot from `mach_absolute_time`, monotonic and unaffected by changes to the wall clock. Storing the measurement time alongside the position lets every consumer extrapolate the current position as `position + (now − measuredAt)` while playing. `AppDelegate.updateSong` (`AppDelegate.swift:278`) builds it from Music's track plus `music.measuredPosition` and `music.measuredAt`.

Because `measuredAt` is part of the synthesized `==`, two `SongInfo`s describing the same moment of the same song but measured at different times are unequal. That matters to `WallpaperManager.setSong`, which uses `!=` to skip redundant updates.

### `NowPlayingSides` — responsibility, state, lifecycle, threading

The class is `@MainActor final`. It is created by its host, lives as long as the host keeps it (a `VideoCanvas` removes it when the song goes away; a `MusicScene` keeps it for its lifetime and hides it), and all of its methods run on the main thread. Its two timers use `onMainActor` (from `HimawariKit/MainThread.swift:8`, which asserts the main thread with a `precondition` and then calls the closure as main-actor-isolated) to get back into the actor from the `Timer` callback.

#### Stored state

| Property | Type | Meaning |
|---|---|---|
| `vfd` (static) | `NSColor` | The display cyan (0.45, 0.97, 1) |
| `amber` (static) | `NSColor` | Amber for the top spectrum segments and the DISC lamp |
| `deck`, `analyzer` | `CALayer` | The two faceplates; their `contents` is the drawn hardware |
| `indicators` | `[CATextLayer]` | PLAY, PAUSE, REPEAT, SHUFFLE words (9 pt bold mono) |
| `time` | `CATextLayer` | Elapsed time, 40 pt light mono |
| `total` | `CATextLayer` | Remaining time `-mm:ss`, 12 pt, right-aligned |
| `ladder` | `[CALayer]` | The 32 progress segments |
| `titleClip` | `CALayer` | Clip box for the scrolling title |
| `title`, `artist`, `album` | `CATextLayer` | The three text lines |
| `playLED` | `CALayer` | Green LED above the play/pause button |
| `jog` | `CALayer` | The jog wheel image layer |
| `pointers` | `[GearControl: CAShapeLayer]` | Live knob pointers for VOLUME, BASS, TREBLE |
| `controlRects` | `[GearControl: CGRect]` (private set) | Each control's rectangle in view coordinates (y up) |
| `previewOffset` | `Double?` | During a jog/disc scrub: seconds from now the song would land |
| `volume` | `Double` | Music's volume 0…1; `didSet` re-points the knobs |
| `bass`, `treble` | `Double` | Equalizer tone in dB, −12…12; `didSet` re-points the knobs |
| `repeating`, `shuffling` | `Bool` | Music's REPEAT/SHUFFLE; `didSet` re-lights the indicators |
| `needles` | `[CALayer]` | The two VU needles (`CAShapeLayer`s) |
| `meterSource` | `AudioLevels?` | The live level source; changing the object restarts motion |
| `meterTimer` | `Timer?` | The 30 Hz live-meter timer |
| `needleLevel` | `[CGFloat]` | Smoothed needle positions (0…~1.03), left/right |
| `bandLevel` | `[CGFloat]` | Smoothed spectrum heights, 10 values, floor 0.07 |
| `columns` | `[CALayer]` | The spectrum column *masks* (what is scaled) |
| `info` | `SongInfo?` | The last song shown |
| `anchor` | `(position: Double, at: CFTimeInterval)` | The view's own clock: a position and when it was true |
| `video` | `CGRect` | The square picture's rectangle; the gear goes in the gaps |
| `ticker` | `Timer?` | One-shot timer for the next second boundary |
| `lively` | `Bool` | False in Battery Saver: no needle/spectrum/jog/marquee motion |
| `animating` | `Bool` | False while the wallpaper is paused (covered, locked) |

### Initialisation and the clock

#### `init(frame:)` (lines 73–79) and `init?(coder:)`

Makes the view layer-backed, adds the two faceplate layers to its root layer and calls `scheduleTick()`. `init?(coder:)` is a `fatalError()` (no nibs). `hitTest` returns `nil`.

#### `scheduleTick()` (lines 83–95)

The digit display is the only element the app updates itself, and it should turn over exactly when the song's next second begins:

```swift
let p = currentPosition()
let delay = info?.playing == true ? 1 - p.truncatingRemainder(dividingBy: 1) + 0.005 : 1
ticker = Timer.scheduledTimer(withTimeInterval: max(delay, 0.02), repeats: false) { [weak self] _ in
    onMainActor {
        guard let self else { return }
        self.updateTime()
        self.scheduleTick()
    }
}
ticker?.tolerance = 0.005
```
(`NowPlayingSides.swift:85–94`)

While playing, the delay is the remaining fraction of the current second plus 5 ms, so the timer lands just after the boundary and `Int(t)` has already ticked over. While paused (or with no song) it re-arms every second. The 0.02 s floor avoids a zero-delay loop. The tolerance of 5 ms permits the system to coalesce timer wake-ups slightly without visibly delaying the digits. The closure captures `self` weakly; if the view is gone the chain stops because nothing re-schedules. The timer keeps running even when the view is hidden or not animating, which costs one wake-up per second.

#### `show(_:)` (lines 100–129)

Called by the host whenever a new `SongInfo` arrives. Steps:

1. `songChanged` is true when title or artist differ from the old info (album is not compared).
2. **Anchoring.** It computes where Music actually is now, `actual = position + (now − measuredAt)` while playing, and compares it to the view's own extrapolated position. It re-anchors only if the song changed, the play state changed, or the drift exceeds 0.15 s. Music's position reports arrive late and slightly jittery; following each one would make the seconds stutter. Counting from a stable anchor gives steady ticks, while a real seek (drift > 0.15 s) still snaps.
3. Stores `info`; if re-anchored, re-times the tick from the new state (for example, right after resuming).
4. On a new song, sets title and artist upper-cased, album as is, and calls `layoutTitle()` to size the title for the marquee.
5. Calls `lightIndicators()`, sets the play LED colour (bright green with a 0.9 shadow glow when playing, dark green and no glow when paused), and calls `updateTime()`.
6. On a new song or play-state change it calls `restartProgress()` and `restartMotion()`; on a large drift only (> 2 s, a seek) only `restartProgress()`.

#### `place(around:)` (lines 132–138)

Records the video rectangle (in the view's y-up coordinates) and rebuilds everything if it changed: `build()`, `restartProgress()`, `restartMotion()`.

#### `currentPosition()` (lines 140–144) and `shownPosition` (line 380)

Returns `anchor.position + (now − anchor.at)` while playing, or `anchor.position` when paused, clamped to `0…duration` (or only to ≥ 0 if the duration is unknown). With no song it returns 0. `shownPosition` exposes it publicly. Despite its doc comment ("including a jog-wheel preview"), it does not add `previewOffset`; only `updateTime` does.

#### `leftGap`, `rightGap`, `roomy` (lines 146–149)

The left gap is from the view's left edge to `video.minX`, the right gap from `video.maxX` to the right edge, both full height. `roomy` requires both gaps to be at least 180 pt wide and the video at least 500 pt tall. On a nearly screen-shaped video the gear is hidden rather than squeezed.

### Building the gear

#### `build()` (lines 153–170)

Inside a `CATransaction` with actions disabled (so no layer property change animates implicitly; Core Animation otherwise gives most property changes on standalone layers a 0.25 s fade), it removes every sublayer of both faceplates, empties `ladder`, `needles`, `columns` and `controlRects`, and hides both faceplates if not `roomy`. Otherwise it reads the window's `backingScaleFactor` (2 if not in a window yet), sets each faceplate to fill its gap inset by 8 pt and vertically to the video's height inset by 8 pt, then builds both.

The text layers created in the property initialisers (`time`, `title`, etc.) are reused across rebuilds; only their frames and parents change.

#### `buildDeck(scale:)` (lines 172–248)

1. Computes a `DeckLayout` for the faceplate size and sets `deck.contents` to `Hardware.deck(...)`.
2. **Indicators.** Inside the display rectangle inset by 14×12 pt it lays the four words left to right at the top, each sized to its text width (`width(of:) + 2`) with 10 pt gaps. REPEAT and SHUFFLE (indices 2, 3) also become controls: their frames, enlarged by 4×5 pt and shifted by the deck's origin into view coordinates, go into `controlRects[.repeatMode]` and `[.shuffle]`.
3. **Time.** `time` takes the left 62 % of the display, 48 pt tall, 64 pt below the top; `total` the right 40 %, right-aligned.
4. **Progress ladder.** 32 segments, 2 pt gaps, 6 pt tall, 78 pt below the top of the inner display, cyan with a 3 pt cyan shadow (the glow; its opacity is set later by `updateTime`).
5. **Title, artist, album.** The title goes inside `titleClip` (20 pt high, `masksToBounds`) so it can scroll; artist and album are plain lines below.
6. **Mesh.** A layer filled with `Hardware.meshColor` (a pattern colour) over the whole display, inset 4 pt, imitates the fine grid in front of a real VFD tube. It is added after the text so it sits on top.
7. **Play LED** at `l.playLED`, round, with a green glow.
8. **Controls.** The five transport buttons map, in order, to `.previous, .playPause, .next, .stop, .eject`. `.progress` gets a 26 pt-tall rectangle around the ladder (easier to hit than 6 pt). `.jog` gets the jog wheel's rectangle.
9. **Jog wheel** layer with `Hardware.jogWheel` contents.
10. Sets `contentsScale` on all text layers so they render at Retina resolution.

#### `buildAnalyzer(scale:)` (lines 250–339)

1. `AnalyzerLayout` and `Hardware.analyzer` contents.
2. **VU needles.** For each meter face, a clip layer (the face's frame, `masksToBounds`, 6 pt corners) holds a `CAShapeLayer` needle: 3 pt wide, 1.12 × face height long, with `anchorPoint` (0.5, 0) so it rotates about its bottom end, positioned 0.28 × face height *below* the face. The pivot is therefore hidden, like on a real meter, and the clip cuts the needle at the face edge. The needle starts at `Hardware.needleRest`. A `CAGradientLayer` (white 28 % to transparent, top to 45 % height) over the needle imitates a reflection on the glass.
3. **Spectrum.** Ten columns of 14 segments in `l.spectrum`, 5 pt column gaps and 2 pt segment gaps. The top three segments are amber, the rest cyan. Each column carries a soft cyan shadow. The moving part is the column's **mask**: a white layer with `anchorPoint` (0.5, 0) at the bottom, sized to the column. Scaling the mask's y from 0.07 to 1 reveals segments from the bottom up while the segments themselves stay put. A layer's `mask` uses the mask layer's alpha channel to decide which pixels of the masked layer are visible. Scaling the mask is cheap for the render server, and the segment edges stay sharp. A `Hardware.meshColor` layer covers the spectrum glass.
4. **Knob pointers.** For each knob that maps to a `GearControl` (all three do), a square `CAShapeLayer` centred on the knob draws a short line pointing up from 12 % to 36 % of the knob's width, 2 pt white, round caps. Rotating this layer about its centre turns the pointer. The control rectangle is the knob enlarged by 10 pt each side. Ends with `pointKnobs()`.

### Being played with

#### `press(_:)` (lines 344–359)

Visual feedback for a click: a white 35 % rounded layer over the control's rectangle on the root layer, faded to zero over 0.35 s. `fillMode = .forwards` and `isRemovedOnCompletion = false` keep it invisible after the animation, and a `DispatchQueue.main.asyncAfter(0.4 s)` removes it. If the control has no rect (not built), nothing happens.

#### `scrub(by:angle:)` and `endScrub()` (lines 362–377)

`scrub` stops the jog wheel's idle `"spin"` animation, sets the jog layer's rotation to `angle` (radians, counter-clockwise positive, as Core Animation's z rotation is in a y-up layer), records `previewOffset = seconds` and refreshes the time. The display therefore previews where the song would land. `endScrub` clears the offset, resets the wheel's transform to identity (the wheel snaps back to its rest orientation), restarts motion (the idle spin) and refreshes the time. `MusicScene`'s disc scrub calls `scrub(by:angle: 0)` so the display previews but the wheel does not turn.

#### `knobValue(_:)` (lines 383–390)

Maps a knob to 0…1 around its scale: volume directly, bass and treble as `(dB + 12) / 24`. Other controls give 0.

#### `pointKnobs()` (lines 392–402)

For each pointer, clamps the value to 0…1 and rotates by `π·0.75 − π·1.5·v`. At v = 0 the pointer is rotated 135° counter-clockwise from straight up (about 7:30 on a clock face), at v = 0.5 straight up (0 dB for tone), at v = 1 135° clockwise (about 4:30). This matches the eleven scale dots drawn by `Hardware.knob`, which run from −0.75π to +0.75π. Actions are disabled so the pointer follows a drag without lag.

#### `lightIndicators()` (lines 404–409)

Sets opacity 1 for lit words and 0.16 for unlit, in order: PLAY if playing, PAUSE if not, REPEAT if `repeating`, SHUFFLE if `shuffling`. The dim words remain faintly visible, like unlit segments on a real display.

#### `layoutTitle()` (lines 411–418)

Sizes the title layer to the larger of the clip width and the text width and positions it so its left edge is at 0. A title wider than the clip overflows to the right and is clipped until the marquee moves it.

### Motion

#### `restartProgress()` and `levelsChanged()` (lines 423–426)

`restartProgress` simply calls `updateTime()` (the ladder is driven by the clock, not by an animation). `levelsChanged()` is the public hook hosts call when `AudioLevels` starts, stops or changes its `hearing` verdict; it calls `restartMotion()`.

#### `restartMotion()` (lines 428–496)

The central state switch. It does nothing without a song, when not `roomy`, or before the analyzer is built. Then:

```
moving = info.playing && lively && animating
live   = moving && meterSource.hearing
```

| moving | live | Needles / spectrum | Jog wheel | Marquee |
|---|---|---|---|---|
| false | false | at rest (needle at `needleRest`, columns at 0.07) | still | runs if `lively && animating` (even when paused) |
| true | false | random keyframe loops | spins | runs |
| true | true | driven by `stepMeters` at 30 Hz | spins | runs |

Steps:

1. Starts or stops the live meters timer.
2. **Marquee.** Re-lays the title and removes its animations. If it overflows the clip and the gear is lively and animating, adds a `CAKeyframeAnimation` on `position.x`: hold at the start for 3 s, slide left by the overflow at 24 pt/s, hold 2 s at the end, then slide back at 2.5× the speed (`travel * 0.4`). The key times are those durations divided by the total. It repeats forever, at 15–30 fps.

```swift
let x0 = title.bounds.width / 2
scroll.values = [x0, x0, x0 - overflow, x0 - overflow, x0]
let travel = Double(overflow) / 24
let totalTime = 3 + travel + 2 + travel * 0.4
scroll.keyTimes = [0, 3 / totalTime, (3 + travel) / totalTime, (5 + travel) / totalTime, 1].map { NSNumber(value: $0) }
```
(`NowPlayingSides.swift:443–447`)

3. **Jog wheel.** If moving, a `CABasicAnimation` on `transform.rotation.z` with `byValue = −2π` over 9 s, repeating (one clockwise turn every 9 s, at 10–20 fps). The key path `transform.rotation.z` is a Core Animation "transform helper" that animates just the z rotation component of the layer's 3D transform.
4. **Needles.** For each needle: remove animations; if not live, set to rest. If moving but not live, build 24 random levels: with 12 % probability a peak in 0.82…0.97 (0 VU to +2), otherwise 0.38…0.8 (about −7 to 0 VU). Each level becomes an angle through `Hardware.needleAngle`. The keyframe animation loops these values (closing back on the first) with `calculationMode = .cubic` (smooth Catmull-Rom-like interpolation rather than linear jumps). The right needle's loop is 0.7 s longer (6.5 s vs 7.2 s), so the two never move in lockstep.
5. **Spectrum.** For each mask: remove animations; if not live, set y-scale 0.07. If moving but not live, 8 random levels between 0.12 and `1 − 0.045·i` (lower bands reach higher), looping over `2.4 − 0.1·i + random(0…0.4)` seconds (higher bands are quicker), at 12–20 fps.

The random values are regenerated on every call, so each play/pause or song change makes a new pattern.

### Live meters

#### `startLiveMeters()` / `stopLiveMeters()` (lines 500–515)

`start` is idempotent. It first calls `meterSource?.read()` and discards the result, so the first frame does not show the maximum of everything that accumulated while nobody was reading (the snapshot holds running maxima). It then schedules a repeating 1/30 s timer with 4 ms tolerance; the closure invalidates the timer if the view is gone. `stop` invalidates and clears it.

#### `stepMeters()` (lines 519–535)

One frame of ballistics:

```swift
for (i, rms) in [s.left, s.right].enumerated() where i < needles.count {
    let target = CGFloat(Self.vuFraction(rms))
    needleLevel[i] += (target - needleLevel[i]) * (target > needleLevel[i] ? 0.4 : 0.16)
    needles[i].transform = CATransform3DMakeRotation(Hardware.needleAngle(Double(needleLevel[i])), 0, 0, 1)
}
for (i, mask) in columns.enumerated() where i < s.bands.count {
    let target = max(CGFloat(s.bands[i]), 0.07)
    bandLevel[i] = target > bandLevel[i] ? target : max(target, bandLevel[i] - 0.04)
    mask.transform = CATransform3DMakeScale(1, bandLevel[i], 1)
}
```
(`NowPlayingSides.swift:524–533`)

If the source is gone or no longer `running`, it stops the timer and calls `restartMotion()` to fall back to self-animation. Otherwise:

- **Needles**: an exponential approach to the target, with coefficient 0.4 per frame when rising and 0.16 when falling. At 30 Hz that is a time constant of about 65 ms up and 190 ms down, which approximates the asymmetric feel of a real VU meter (a true VU meter is specified as a symmetric 300 ms integration; the asymmetry here is a stylistic choice).
- **Spectrum**: peak-hold with linear decay. A higher target jumps immediately; otherwise the column falls by at most 0.04 per frame (about 1.2 full heights per second), never below 0.07.

#### `vuFraction(_:)` (lines 539–549)

Converts an RMS value (0…1 of full scale) to a position on the drawn scale. First `vu = 20·log10(rms) + 14`: the RMS in dBFS, offset so 0 VU means −14 dBFS (the comment's reasoning: modern masters sit there, so the needle hovers near 0). The function then interpolates piecewise-linearly between the scale's printed marks, the same `(level, fraction)` pairs `Hardware.vuFace` uses to print the numbers: −20 → 0, −10 → 0.28, −7 → 0.42, −5 → 0.53, −3 → 0.64, −2 → 0.7, −1 → 0.76, 0 → 0.82, +1 → 0.88, +2 → 0.94, +3 → 1. Below −20 it returns 0; above +3 it returns 1.03, so the needle pins slightly past the end of the scale. RMS is floored at 1e-6 to avoid `log10(0)`.

#### `updateTime()` (lines 551–567)

Computes `p = currentPosition() + previewOffset`, clamped to `0…duration`, and formats `mm:ss`. **It returns early if the displayed time string already equals the new one** (unless `total` has never been set), so the ladder and remaining time are only redrawn when the seconds digit changes. Otherwise it sets `time` and `total` (`-mm:ss` remaining, or empty if the duration is unknown), and lights `ceil(p / duration × 32)` ladder segments (opacity 1 and glow 0.8) and dims the rest (opacity 0.13, no glow). Rounding up means the first segment lights as soon as playback starts.

### Helpers

`text(_:_:alpha:mono:)` (lines 571–583) creates a `CATextLayer` with the system font or monospaced system font at the given size and weight, cyan foreground at the given alpha, end truncation, `contentsScale` 2, and a 3.5 pt cyan shadow at 0.7 opacity: the glow of a fluorescent display. Monospaced digits keep the time from jittering as digits change width.

`width(of:)` (lines 585–588) measures a text layer's string with its font through `NSAttributedString.size()`, rounds up and adds 2 pt. It returns 0 if the string or font is not of the expected type.

### `DeckLayout` (lines 593–615)

A private value type that computes all deck rectangles from the faceplate size, top to bottom, in a central column at most 300 pt wide:

| Property | Computation |
|---|---|
| `column` | width `min(size.width − 32, 300)`, centred; 18 pt top/bottom margins |
| `header` | top 40 pt of the column (brand and model text) |
| `display` | 164 pt tall, 14 pt below the header |
| `tray` | 16 pt slot, 26 pt below the display |
| `buttons` | 34 pt row, 24 pt below the tray |
| `buttonRects` | 5 equal buttons with 8 pt gaps |
| `playLED` | 6×6 pt, centred 5 pt above button 2 (play/pause) |
| `jog` | diameter `d = max(min(colW − 40, space − 30, 190), 60)`, centred in the space between the buttons and the power row (70 pt kept at the bottom) |

The diameter formula keeps the wheel at most 190 pt, at least 60 pt, and smaller than the space available.

### `AnalyzerLayout` (lines 617–644)

| Property | Computation |
|---|---|
| `column`, `header` | as in `DeckLayout` |
| `meters` | two faces, height `min(colW × 0.52, 150)`, 14 pt below the header and 12 pt apart |
| `spectrumGlass` | 24 pt below the second meter; height `max(min(available, 200), 90)` where `available` leaves a 78 pt knob row plus 20 pt |
| `labels` | 10 pt strip at the bottom of the glass, inset 12 pt |
| `spectrum` | the bars' area above the labels, glass height − 34 |
| `knobs` | `(rect, name)` pairs: BASS (40 pt) at 18 %, TREBLE (40 pt) at 45 %, VOLUME (56 pt) at 78 % of the column width, all vertically centred on a 56 pt row 22 pt above the column bottom |

### `Hardware` (lines 648–905)

A private, caseless `@MainActor enum` used as a namespace for drawing. All drawing happens in AppKit's `NSBezierPath`/`NSGradient` API, bridged to a bitmap `CGContext`.

| Member | What it does |
|---|---|
| `needleRest` | 0.82 rad: the needle's resting angle, a little further left than the −20 mark (0.72 rad), as on real meters at rest |
| `needleAngle(_:)` | `0.72 − level × 1.44`: maps a scale fraction 0…1 to +0.72…−0.72 rad (positive = counter-clockwise = left) |
| `meshColor` | A lazily created `CGColor` pattern from a 3×3 image with a dark row and column (35 % black): a fine grid |
| `image(size:scale:draw:)` | Creates an sRGB, 8-bit, premultiplied-alpha bitmap context `size × scale` pixels, scales the CTM by `scale` so drawing is in points, installs it as the current `NSGraphicsContext` (unflipped) so AppKit drawing calls target it, runs `draw`, restores, and returns `makeImage()`. Returns `nil` for an empty size. |
| `faceplate(_:)` | Rounded plate with a three-stop vertical grey gradient (97 % opaque), then one 1 pt line per row of random black or white at 1–4.5 % alpha (the brushing, clipped to the plate), a 1 pt highlight stroke, and four screws: a radial-looking linear gradient disc with a diagonal slot |
| `header(_:brand:model:)` | Brand in 15 pt heavy with 4 pt kerning; model in 8.5 pt; an engraved line (light over dark 1 pt rules) |
| `glass(_:)` | A display window: a 2 pt black bezel, a very dark teal gradient, a faint highlight stroke |
| `label(_:centeredAt:size:alpha:)` | Small bold kerned label centred on a point |
| `deck(size:layout:scale:)` | Faceplate, header "HIMAWARI / COMPACT DISC PLAYER HD-2160", display glass, disc tray slot with "OPEN / CLOSE", "DISC" and an amber lamp, the five gradient buttons with SF Symbols (`backward.end.fill`, `playpause.fill`, `forward.end.fill`, `stop.fill`, `eject.fill`), a power switch with a green lamp, a headphone jack, and a dark well behind the jog wheel labelled "JOG" |
| `analyzer(size:layout:scale:)` | Faceplate, header "STEREO LEVEL ANALYZER SA-10", two VU faces (L, R), the spectrum glass with frequency labels 31 … 16k (matching `AudioLevels.centers`), and the three knobs |
| `vuFace(_:channel:)` | Amber backlit face (radial gradient), the scale arc of radius 0.98 × height about the hidden pivot, a thick red arc from 0 VU to +3, tick marks and numbers at the same fractions as `vuFraction` (red above 0), "VU" and the channel letter |
| `knob(_:label:pointer:)` | Drop shadow, outer and inner gradient discs, optionally a static pointer at 45° (never drawn now: every knob has a live pointer), eleven scale dots from −0.75π to +0.75π, and the label below |
| `symbol(_:in:)` | Draws an SF Symbol at 11 pt bold in a light palette colour, centred in a rectangle |
| `amberLamp`, `greenLamp`, `lamp` | A 12 pt translucent halo with a 6 pt solid centre |
| `jogWheel(diameter:scale:)` | Grey gradient disc; 90 alternating dark/light knurling ticks on the outer 12 % of the radius; a brushed inner face with concentric rings every 2.5 pt; and a finger dimple off-centre so the rotation is visible |

The angle convention in `vuFace` and `knob` is that angle *a* from straight up, counter-clockwise, gives the point `(cx − sin a · r, cy + cos a · r)`; this matches `CATransform3DMakeRotation` with positive angles turning counter-clockwise in a y-up layer, so drawn ticks and rotated needles agree.

Because `faceplate` uses `SystemRandomNumberGenerator`, the brushing differs every time the gear is rebuilt.

### `GearControl` (lines 908–924)

A `Hashable` enum naming every interactive part: `previous`, `playPause`, `next`, `stop`, `eject`, `progress` (click the ladder to jump), `jog` (turn to scrub), `volume`, `bass`, `treble` (drag up/down; double-click bass/treble for flat), `repeatMode`, `shuffle`. The failable `init?(knob:)` maps the drawn knob labels "VOLUME", "BASS", "TREBLE" to cases. It is used both to decide which knobs get live pointers and, in `Hardware.analyzer`, whether to draw a static pointer.

### Notes and risks

- `NowPlayingSides.swift:556` — `updateTime` returns early when the time string is unchanged. After `build()` recreates the 32 ladder segments (lines 203–212, default opacity 1), `place(around:) → restartProgress() → updateTime()` usually finds the same `mm:ss` and returns, so the ladder shows fully lit until the next second changes; while paused, that never happens.
- `NowPlayingSides.swift:556` — the same guard means a new song whose first displayed time equals the old song's displayed time (for example two songs both at `00:00`) keeps the previous song's remaining time and ladder until the next second.
- `NowPlayingSides.swift:83–95` — the tick timer runs once a second even with no song, hidden gear or `animating == false`.
- `NowPlayingSides.swift:379–380` — `shownPosition`'s doc comment says it includes the jog preview; it does not.
- `NowPlayingSides.swift:848` — the comment says "the VOLUME knob gets a live pointer layer instead"; all three knobs do, and `drawPointer` is always false (line 793).
- `NowPlayingSides.swift:240` — the `.progress` hit rectangle (from `maxY − 88` to `maxY − 62`) slightly overlaps the bottom of the `time` layer's frame (`maxY − 64`).
- `NowPlayingSides.swift:102` — a song change is detected by title and artist only; two consecutive tracks with the same title and artist (e.g. a live and a studio version) would not re-anchor via `songChanged`, though the drift check would usually catch it.
- `controlRects` changes in `build()` are not pushed to `GearControls`; catchers follow on the next `refreshControls()` (the 2 s watchdog in `WallpaperManager.swift:446` or the next `applySong`), so they can be misplaced for up to 2 s after a layout change.

---

## Sources/Himawari/GearControls.swift

### Purpose and place in the app

The wallpaper windows sit at `desktop + 1` (`DesktopLayer.video`, `DesktopWindow.swift:9`), below Finder's full-screen icon window at about +20, which swallows every desktop click. To make the gear clickable without making the whole wallpaper intercept clicks, `GearControls` creates one small borderless `NSPanel` per control at level `desktop + 22` (`DesktopLayer.folders`, the same level as Himawari's folder dock), placed exactly over that control. Everything around those rectangles still belongs to the desktop.

`WallpaperManager` owns one instance (`WallpaperManager.swift:24`) and calls `update(gear:scenes:active:)` from `refreshControls()` (line 331), which runs at the end of every `applySong` and every 2 s from the watchdog. `active` is `gearActive`: the desktop is visible, no YouTube video covers it, a song exists, and at least one gear view is visible (line 335). `AppDelegate` wires the three closures at `AppDelegate.swift:95–131`.

The file contains `GearControls` (with nested `Action` and `Turn`), the private `Catcher` panel and `CatcherView`, the public `ScratchSound` and the private `ScratchState`.

### Design decisions

- **Separate windows, not one big interactive window.** A single interactive window over the gear would also need to pass clicks through everywhere else. macOS decides click-through per window and per pixel alpha, so small windows exactly over the controls are simplest.
- **Not-quite-transparent backgrounds.** The window server sends clicks on fully transparent pixels of a non-opaque window to the window below. `CatcherView` fills itself with black at alpha 0.004 (line 237), invisible but enough to receive clicks.
- **Closures, not delegates.** Each catcher stores `onDown`/`onDrag`/`onUp`/`onDoubleClick` closures configured per control; state such as the drag's start point lives in variables captured by those closures.
- **Diffing by key.** Panels are reused across updates when their key (view identity plus control) persists, so a 2 s refresh does not recreate windows.
- **Sound is synthesized.** The scratch sound is computed in a render callback, so there are no audio assets, and the `AVAudioEngine` runs only while a disc or wheel is held plus 0.6 s.

### `GearControls` — state, lifecycle, threading

`@MainActor final class`, created once by `WallpaperManager` and kept for the app's life.

| Property | Type | Meaning |
|---|---|---|
| `perform` | `((Action) -> Void)?` | What to do with an action; set by `AppDelegate` to issue Music commands |
| `song` | `() -> (position: Double, duration: Double)?` | Current position and length, for scrub limits; default returns nil |
| `volumeNow` | `(@escaping (Double) -> Void) -> Void` | Asynchronously fetches Music's volume 0…1; default answers 0.5 |
| `catchers` | `[Catcher]` | The live panels |
| `scratch` | `ScratchSound` | The scratch sound generator |

#### `Action` (lines 14–20)

| Case | Sent by | `AppDelegate` response |
|---|---|---|
| `.button(GearControl)` | transport buttons, REPEAT, SHUFFLE | previous / playPause / next; stop = `pause()`; eject = open Music; repeat/shuffle toggle the deck and call `setRepeat`/`setShuffle` |
| `.seek(fraction:)` | click on the ladder | `seek(to: fraction × duration)` |
| `.scrub(seconds:)` | releasing the jog wheel or the disc | `seek(to: max(0, position + seconds))` |
| `.volume(Double, done:)` | VOLUME knob | sets Music's volume at most every 0.1 s, plus the final value |
| `.tone(bass:treble:done:)` | BASS/TREBLE knobs | `setTone`: switches Music to Himawari's EQ preset, rate-limited to every 0.25 s while dragging, final value 0.3 s after release |

### `update(gear:scenes:active:)` (lines 33–67)

1. Builds a `wanted` list of `(key, screenRect, make)`. If `active`:
   - for every gear view in a window, for every entry in its `controlRects`, converts the rect to screen coordinates and adds key `"<ObjectIdentifier(view)>.<control>"` with a factory calling `catcher(for:gear:)`;
   - for every `MusicScene` in a window with a non-empty `discRect`, adds key `"<ObjectIdentifier(scene)>.disc"` with `discCatcher(_:)`.
   The factories capture `self` as `unowned`; `GearControls` outlives the call, so that is safe.
2. For each existing catcher: if its key is wanted, move it (`setFrame(_:display: false)`) and keep it; otherwise `orderOut(nil)` (hide) and drop it.
3. For each wanted key with no kept catcher: create it, set key and frame, `orderFrontRegardless()` (show it without activating Himawari), keep it.
4. Replaces `catchers` with the kept list.

With `active == false` every catcher is hidden and dropped. The lookups are linear (`first(where:)`, `contains(where:)`) over at most a few dozen items.

#### `screenRect(_:in:)` (lines 69–72)

`view.convert(rect, to: nil)` gives window coordinates, `window.convertToScreen` gives global screen coordinates (y up from the bottom of the main screen), which is what `NSWindow.setFrame` expects. Returns nil if the view is not in a window.

### `catcher(for:gear:)` (lines 76–143)

Creates a `Catcher` and configures it for the control. The gear view is captured weakly everywhere.

- **Buttons** (`previous`, `playPause`, `next`, `stop`, `eject`, `repeatMode`, `shuffle`): on mouse down, flash the control (`gear.press`) and send `.button(control)`. Acting on mouse-down (not mouse-up) makes the gear feel immediate.
- **Progress**: on mouse down, reads the ladder's width from `controlRects`, flashes, and sends `.seek(fraction: clamp(x / width, 0, 1))`. The catcher's local x equals the offset along the ladder, since the panel has exactly the rect's size.
- **Jog**: one turn = 10 seconds, clockwise is forward. A `Turn` value is captured by all three closures.
  - Down: `turn.begin` with the panel's content bounds; `scratch.start()`.
  - Drag: `step = turn.move(to:)`; `gear.scrub(by: clamped(−total/2π × 10), angle: total)` (negated because `Turn` counts counter-clockwise positive); `scratch.speed = |step| × 60`.
  - Up: computes the clamped seconds, `endScrub()`, `scratch.stop()`, and sends `.scrub(seconds:)` only if it exceeds 0.2 s, so a click without a real turn does nothing.
- **Volume**: 150 pt of vertical drag spans silent to full. On down, stores the start y and asks `volumeNow` for Music's actual volume, setting `level` and the knob when it answers (asynchronously; `AppDelegate` uses `music.fetchVolume`). Drag and up compute `clamp(level + Δy/150, 0, 1)`, set `gear.volume`, and send `.volume(v, done:)`.
- **Bass / treble**: same gesture, 150 pt across ±12 dB. `send(v, done)` converts 0…1 to dB rounded to half-dB steps (`((v·24 − 12)·2).rounded() / 2`), sets `gear.bass` or `gear.treble`, and sends `.tone` with *both* current values (the preset holds both). On down, `level` comes from `gear.knobValue(control)`, which is synchronous. A double-click flashes the knob and sends flat (0.5, i.e. 0 dB).

### `discCatcher(_:)` (lines 146–169)

The CD in `MusicScene` can be grabbed and turned like a record; one full turn is 8 seconds. The catcher is `round`.

- Down: `turn.begin`, `scene.grabDisc()` (stops the disc's spin animation at its current presentation angle), `scratch.start()`.
- Drag: `scene.turnDisc(by: total)` makes the disc follow the hand; the scene's gear previews the time with `scrub(by:angle: 0)`; scratch speed as above.
- Up: `releaseDisc()` (the disc spins on), `endScrub()`, `scratch.stop()`, and `.scrub(seconds:)` if beyond 0.2 s.

### `clamped(_:)` (lines 172–175)

Limits a scrub offset to `[−position, max(duration − position − 1, 0)]`: never before the start, and never closer than one second to the end (seeking to the very end would skip to the next track). Without song information it returns the value unchanged.

### `Turn` (lines 178–197)

A small value type that integrates the angle of a drag around a centre point.

| Property | Type | Meaning |
|---|---|---|
| `center` | `CGPoint` | Centre of the catcher's bounds |
| `last` | `CGFloat` | Angle of the previous point, radians |
| `total` | `CGFloat` (private set) | Accumulated turn, radians, counter-clockwise positive |

`begin(at:in:)` sets the centre, `last = atan2(dy, dx)` and resets `total`. `move(to:)` computes the new angle and the step `angle − last`. `atan2` returns values in (−π, π], so crossing the negative x-axis would look like a jump of almost 2π; the step is unwrapped by adding or subtracting 2π when it exceeds ±π (line 192). The function adds the step to `total` and returns it. This allows several full turns in one drag. Because `Turn` is a struct captured by three escaping closures, Swift boxes the variable on the heap and all three share it.

### `Catcher` (lines 203–226)

A private `@MainActor` `NSPanel` subclass.

| Property | Type | Meaning |
|---|---|---|
| `key` | `String` | Diffing key set by `update` |
| `round` | `Bool` | Disc catcher; forwarded to the view |
| `onDown`, `onDrag`, `onUp` | `((CGPoint) -> Void)?` | Handlers, point in the content view's coordinates |
| `onDoubleClick` | `(() -> Void)?` | Handler for a click with `clickCount == 2` |

`init()` creates a borderless, **non-activating** panel: `.nonactivatingPanel` means clicking it does not make Himawari the active app or steal focus from the frontmost app, which matters for something that lives on the desktop. Level is `desktop + 22`. `collectionBehavior` `[.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]` keeps it on every Space, fixed during Mission Control / Exposé, out of Cmd-` window cycling, and out of full-screen spaces. It is transparent, shadowless, does not hide when the app deactivates, and is not released on close. `canBecomeKey` is `false`, so it never takes keyboard focus.

### `CatcherView` (lines 229–260)

| Property | Type | Meaning |
|---|---|---|
| `owner` | `Catcher?` (weak) | The panel whose handlers to call |
| `round` | `Bool` | Whether only the inscribed circle is clickable |

- `init(frame:)`: layer-backed with a 0.4 % black background (see design decisions).
- `layout()`: corner radius half the width for the disc, 6 pt otherwise (cosmetic; the background is invisible).
- `acceptsFirstMouse(for:)` returns true, so the first click on an inactive app's window acts instead of only activating.
- `hitTest(_:)`: for the round catcher, converts the point from the superview and returns `self` only within the circle; otherwise `nil`, letting that click fall to the window below. (The rest of the square panel still has the 0.004 alpha background, so the window server delivers clicks there to this window, which then ignores them; they do not reach Finder.)
- `mouseDown`: if `clickCount == 2` and a double-click handler exists, calls it and returns; otherwise `onDown` with the point in view coordinates. `mouseDragged` and `mouseUp` call `onDrag` and `onUp`. While the mouse is down AppKit routes dragged and up events to the view that received the down, even outside the panel, so a jog-wheel drag can leave the small panel.

### `ScratchSound` (lines 265–304)

The sound of a disc turned by hand: filtered noise plus a low whirr whose loudness and pitch follow the turning speed.

| Property | Type | Meaning |
|---|---|---|
| `speed` | `Double` | Roughly 0…10; `didSet` copies it into `state` |
| `engine` | `AVAudioEngine?` | Exists only while sounding |
| `state` | `ScratchState` | Generator state shared with the audio thread |
| `stopWork` | `DispatchWorkItem?` | Pending engine shutdown |

**AVAudioEngine** is AVFoundation's graph-based real-time audio API: nodes (sources, effects, mixers) are attached to an engine and connected; the engine's `mainMixerNode` feeds `outputNode`, the default output device. **`AVAudioSourceNode`** is a node whose samples come from a render block that the engine calls on its real-time audio thread whenever it needs `frames` more samples, passing an `AudioBufferList` to fill.

`start()` cancels a pending shutdown. If no engine exists, it reads the output's sample rate (48 kHz fallback), creates a source node whose block calls `state.render`, connects it to the main mixer in the standard format (32-bit float, non-interleaved) with 2 channels, sets the mixer's volume to 0.6 and starts the engine. A start failure is logged and leaves `engine` nil. It then sets `speed = 0`, so the sound starts silent and grows as you turn. The block captures `state` (not `self`), so the audio thread never touches the main-actor object.

`stop()` sets `speed = 0` (the generator fades out on its own) and schedules a work item 0.6 s later that stops and discards the engine. Grabbing again within 0.6 s cancels it in `start()`, reusing the running engine.

### `ScratchState` (lines 308–329)

`@unchecked Sendable` because it is shared between the main thread (which writes `speed`) and the audio thread (which reads it and owns everything else). The comment accepts the formally racy `Double` access: an aligned 64-bit store is atomic on Apple's 64-bit CPUs in practice, and a stale value only affects one buffer.

| Property | Type | Meaning |
|---|---|---|
| `speed` | `Double` | Target speed from the main thread |
| `level` | `Double` | Smoothed loudness 0…1 |
| `lowpass` | `Double` | One-pole low-pass filter state |
| `phase` | `Double` | Phase of the whirr oscillator, radians |
| `seed` | `UInt32` | Linear congruential generator state |

#### `render(frames:rate:into:)` (lines 313–328)

Per sample:

1. `level` approaches `min(speed/10, 1)` by 0.15 % per sample, a time constant of about 670 samples (~14 ms at 48 kHz): no clicks when the speed jumps.
2. White noise from a 32-bit LCG (`seed·1664525 + 1013904223`, the Numerical Recipes constants, with wrapping `&*` / `&+`), mapped to −1…1. No allocation and no locks, as real-time code requires.
3. A one-pole low-pass `lowpass += (noise − lowpass) × cutoff` with `cutoff = 0.02 + 0.25 × level`: faster turns let more high frequencies through and sound brighter.
4. A sine whose frequency rises from 50 Hz to 350 Hz with `level`.
5. `sample = (0.6 × lowpass + 0.15 × sin(phase)) × level × 0.35`, written to every buffer (both channels) at index `i`.

```swift
level += (target - level) * 0.0015                  // smooth fades, no clicks
seed = seed &* 1664525 &+ 1013904223
let noise = Double(Int32(bitPattern: seed)) / Double(Int32.max)
let cutoff = 0.02 + 0.25 * level                     // faster turns sound brighter
lowpass += (noise - lowpass) * cutoff
phase += 2 * .pi * (50 + 300 * level) / rate          // the whirr rises with speed
```
(`GearControls.swift:316–321`)

The speed passed in is `|step| × 60`, where `step` is the radians turned since the last drag event; a quarter turn per event (fast) gives ~94, so the target saturates at 1 for anything but slow turns.

### Notes and risks

- `GearControls.swift:93` and `:151` — the jog and disc `onDown` closures capture the `Catcher` `c` strongly, and `c` stores those closures: a retain cycle. When `update` drops such a catcher (line 56) it is only ordered out and never deallocated.
- `GearControls.swift:136–139` with `:255`, `:259` — double-click to flatten BASS/TREBLE is undone by the second mouse-up: the second `mouseDown` (clickCount 2) calls `onDoubleClick` and sends 0 dB, but the following `mouseUp` still calls `onUp`, which resends `level + Δy/150` using the `start`/`level` from the *first* click, i.e. the old value. Since `setTone` acts on the last `done` value after 0.3 s, the old value wins.
- `GearControls.swift:136` — a single click on BASS or TREBLE without dragging sends `.tone(done: true)`, which in `AppDelegate.setTone` switches Music's equalizer on with Himawari's preset even though nothing changed.
- `GearControls.swift:107–113` — `level` starts at 0.5 and is replaced when `volumeNow` answers asynchronously; a drag before the answer starts from 0.5, and the answer arriving mid-drag makes the knob jump.
- `GearControls.swift:39` — keys use `ObjectIdentifier(view)`; if a gear view is freed and a new one is allocated at the same address, the old catcher (with a nil weak `gear`) is kept and that control stops responding (buttons still send actions; progress and knobs do nothing).
- `GearControls.swift:213` — catchers sit above Finder's icons, so desktop icons under the gear's controls cannot be clicked there; they share level +22 with the folder dock.
- `GearControls.swift:308–311` — `ScratchState.speed` is an unsynchronised cross-thread `Double` (acknowledged in the comment); technically a data race under Swift's memory model.
- `AudioLevels` uses a global tap when Music's process object is not found (`AudioLevels.swift:96`); that tap would also hear `ScratchSound`, so scrubbing would move the meters.

---

## Sources/Himawari/AudioLevels.swift

### Purpose and place in the app

`AudioLevels` measures the audio Music is playing, without recording it, and offers a `Snapshot` of left/right RMS and ten band levels for the gear's meters. `WallpaperManager` owns one instance (`WallpaperManager.swift:31`) for the app's lifetime. In `applySong` (lines 380–420) it calls `start()` when gear is shown, the desktop is visible and the song is playing, and schedules `stop()` 15 seconds after that stops being true (so window switches do not rebuild the tap). It passes the instance to every gear view as `meterSource`. Every 2 s the watchdog calls `checkHearing()` (line 424), which tells the gear when `hearing` changes. `onPermission` is set to re-run `applySong` after the user grants access (line 83).

### Core Audio concepts used

- **Audio objects and properties.** The Core Audio HAL (hardware abstraction layer) exposes the system (`kAudioObjectSystemObject`), devices, streams, processes and taps as `AudioObjectID`s. Information is read with `AudioObjectGetPropertyData(object, &address, qualifierSize, qualifier, &size, &data)`. An `AudioObjectPropertyAddress` names a property by **selector** (which property), **scope** (global, input, output) and **element** (channel or main). Some properties take a *qualifier*, an input value such as a PID. Calls return an `OSStatus`; `noErr` (0) is success.
- **Process objects.** Since macOS 14 the HAL has an audio object per process producing audio. `kAudioHardwarePropertyTranslatePIDToProcessObject` maps a PID to it.
- **Process taps.** `AudioHardwareCreateProcessTap` (macOS 14.2) creates a tap object that receives a copy of the audio some processes send to output. A `CATapDescription` says which processes (or all except some), whether to mix down to mono or stereo, whether it is private (visible only to the creating process), and the **mute behaviour** (`.unmuted` keeps the user hearing the audio; other modes silence the original while tapping).
- **Aggregate devices.** A tap is not a device and cannot be read directly. An *aggregate device* combines sub-devices (and, since 14.2, taps) into one virtual device. Its tap list makes the tap's audio appear as input streams of the aggregate. One sub-device serves as the clock (`kAudioAggregateDeviceMainSubDeviceKey`); `kAudioSubTapDriftCompensationKey` resamples the tap if its clock drifts from that main device; `kAudioAggregateDeviceTapAutoStartKey` starts the tap when the device starts; `IsPrivate` hides the aggregate from other apps and from Audio MIDI Setup; `IsStacked = false` makes it a multi-input aggregate rather than a "stacked" one that plays to all outputs.
- **IO procs.** `AudioDeviceCreateIOProcIDWithBlock` registers a block the HAL calls each IO cycle with input and output `AudioBufferList`s; giving it a dispatch queue makes it run there instead of the real-time IO thread. `AudioDeviceStart` / `AudioDeviceStop` run and halt it.
- **Stream formats.** `AudioStreamBasicDescription` (ASBD) describes PCM: sample rate, format flags (float, interleaved or not), channels per frame. **Interleaved** means one buffer holding L R L R…; **non-interleaved** means one buffer per channel.
- **TCC permission.** Taps on other apps need the "Screen & System Audio Recording ▸ System Audio Recording Only" permission and an `NSAudioCaptureUsageDescription` in `Info.plist` (present at `Resources/Info.plist:27`). Without permission, a tap is still created but delivers silence, which is why this class checks `AudioPermission` first and also monitors whether it hears anything.

```
 Music.app ──audio──► output device (speakers / AirPods)
      │                         ▲ main sub-device (clock)
      └─ copy ─► process tap ──►│ aggregate device "Himawari Levels" (private)
                                      │ input AudioBufferList each IO cycle
                                      ▼
                           IO block on `queue` (userInteractive)
                           process(): RMS L/R, mono → push → analyze (FFT)
                                      │ max-merge under `pending` lock
                                      ▼
                           read() on main, 30 Hz ─► NowPlayingSides.stepMeters
```

### Accelerate concepts used

- **vDSP** is Accelerate's vectorised signal-processing library. `vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self)` creates (and pre-computes twiddle factors for) a 1024-point FFT setup. It is optional because creation can fail.
- **Split complex** (`DSPSplitComplex`) stores real and imaginary parts in two separate arrays, the layout vDSP's FFT works on.
- **Packed real FFT.** For real input of length N, vDSP views it as N/2 complex numbers (even samples as real parts, odd samples as imaginary parts). `vDSP_ctoz` (complex-to-split, "z" for split) de-interleaves into the two arrays. The forward transform then produces N/2 complex bins, bin *k* at frequency *k × sampleRate / N*, with the DC and Nyquist terms packed together into bin 0. vDSP's real FFT output is scaled by 2 relative to the textbook DFT.
- **Window.** `vDSP.window(.hanningDenormalized, count: 1024)` returns a Hann window (peak 1). Multiplying the block by it before the FFT reduces spectral leakage (energy of one frequency smearing across bins), at the cost of halving the coherent gain.
- `vDSP.multiply` (element-wise product) and `vDSP.squareMagnitudes` (re² + im² per bin) produce the power spectrum.

### State

`AudioLevels` is a `final class` marked `@unchecked Sendable`: some state is touched only on the main thread, some only on the IO queue, and shared state is behind locks. The compiler cannot verify this split.

| Property | Type | Thread | Meaning |
|---|---|---|---|
| `bandCount` (static) | `Int` | — | 10 |
| `centers` (static) | `[Double]` | — | Octave band centres 31 Hz … 16 kHz |
| `pending` | `OSAllocatedUnfairLock<Snapshot>` | both | Measurements since the last `read()` |
| `lastHeard` | `OSAllocatedUnfairLock<CFTimeInterval>` | both | When the tap last carried sound |
| `startedAt` | `CFTimeInterval` | main | When the tap started |
| `tapID`, `aggregateID` | `AudioObjectID` | main | The tap and aggregate device, or unknown |
| `procID` | `AudioDeviceIOProcID?` | main | The IO proc |
| `queue` | `DispatchQueue` | — | Serial `userInteractive` queue for the IO block |
| `running` | `Bool` (private set) | main | Started successfully |
| `failedAt` | `Date?` | main | Last failure, to rate-limit retries to once a minute |
| `watchingOutput` | `Bool` | main | The output-device listener is installed |
| `problem` | `String` (private set) | main | Human-readable last status, for the log |
| `onPermission` | `(() -> Void)?` | main | Called after permission is granted |
| `n` | `Int` | — | FFT size, 1024 |
| `fft` | `vDSP.FFT<DSPSplitComplex>?` | queue | FFT setup |
| `window` | `[Float]` | queue | Hann window |
| `mono` | `[Float]` | queue | Accumulating 1024-sample mono block |
| `filled` | `Int` | queue | Samples in `mono` |
| `real`, `imag` | `[Float]` | queue | Split-complex buffers, 512 each |
| `power` | `[Float]` | queue | Power spectrum, 512 bins |
| `bandBins` | `[Range<Int>]` | written main, read queue | FFT bin ranges per band |
| `interleaved` | `Bool` | written main, read queue | Tap format layout |

`OSAllocatedUnfairLock` (from `os`, macOS 13+) wraps `os_unfair_lock` with heap-allocated storage, so it is safe to use from Swift. `withLock` runs a closure with exclusive access to the protected value. An unfair lock is very cheap when uncontended, which makes it a reasonable choice even from a high-priority audio queue, because the critical sections here are a handful of `max` operations.

#### `Snapshot` (lines 16–19)

| Property | Type | Meaning |
|---|---|---|
| `left`, `right` | `Float` | Largest per-callback RMS since the last read, 0…1 of full scale |
| `bands` | `[Float]` | Largest band level since the last read, 0…1 |

Keeping the maximum over the interval (rather than the latest value) means that a 30 Hz reader never misses a transient that fell between reads.

### `read()` (lines 50–56)

Under the lock, returns the pending snapshot and replaces it with a zeroed one.

### `start()` (lines 61–142)

Main thread. Returns `true` when running.

1. Already running → true. Installs the output-device watcher (once).
2. If the last failure was less than 60 s ago, returns false (no rapid retries, no repeated permission prompts).
3. **Permission** via `AudioPermission.status`:
   - `.denied` → records a problem naming the System Settings location, marks failure, false.
   - `.unknown` → marks failure and calls `AudioPermission.request`; when the user answers, logs it, and if granted clears `failedAt` and calls `onPermission` so the owner starts again. Returns false for now.
   - `.authorized` → continues.
4. Finds Music's PID through `NSRunningApplication` (`com.apple.Music`); if not running, records the problem and returns false (without setting `failedAt`, so it can retry as soon as Music launches).
5. **Process object.** Reads `kAudioHardwarePropertyTranslatePIDToProcessObject` on the system object with the PID as qualifier:

```swift
var pidValue = pid
var size = UInt32(MemoryLayout<AudioObjectID>.size)
let found = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<pid_t>.size), &pidValue, &size, &process) == noErr
    && process != kAudioObjectUnknown
let description = found ? CATapDescription(stereoMixdownOfProcesses: [process])
                        : CATapDescription(stereoGlobalTapButExcludeProcesses: [])
```
(`AudioLevels.swift:90–96`)

   If the process object is found, the tap is a stereo mix-down of Music only. Otherwise (e.g. Music has not yet produced audio, so has no process object), the fallback is a global tap of every process, which is "still mostly Music".
6. Configures the description: a fresh UUID (needed to reference the tap from the aggregate), name, private, unmuted. Creates the tap with `AudioHardwareCreateProcessTap`.
7. Reads the tap's ASBD (`kAudioTapPropertyFormat`). Requires a positive sample rate. Records whether it is interleaved (`kAudioFormatFlagIsNonInterleaved` not set).
8. **Band bins.** With `binHz = sampleRate / 1024`, each band covers one octave around its centre, from `centre/√2` to `centre·√2`:

```swift
let lo = max(1, Int((center / 2.squareRoot() / binHz).rounded(.down)))
let hi = min(n / 2, max(lo + 1, Int((center * 2.squareRoot() / binHz).rounded(.up))))
return lo..<hi
```
(`AudioLevels.swift:112–114`)

   Bin 0 (DC and the packed Nyquist value) is excluded; every range contains at least one bin; the top is limited to 512.
9. Gets the default output device's UID and creates the aggregate device dictionary: name "Himawari Levels", a random UID, that output as main and only sub-device, private, not stacked, tap auto-start, and a tap list containing the tap's UUID with drift compensation. `AudioHardwareCreateAggregateDevice` creates it.
10. Registers an IO block on `queue` capturing `self` weakly, which calls `process(input)` with the input buffer list.
11. `AudioDeviceStart`. On success, records the format in `problem` (logged by the owner), sets `running`, `startedAt`, clears `failedAt`.

Every failing step goes through `fail(_:_:)`, which records the step and `OSStatus`, tears down whatever was built, and sets `failedAt`.

### `hearing` (lines 146–150)

True when running and either started less than 4 s ago (grace period) or the last non-silent buffer was less than 4 s ago. This solves the silent-tap problem: a tap without permission (or with permission revoked later) delivers zeros. `checkHearing` in `WallpaperManager` switches the gear to self-animation when `hearing` goes false while the song plays, and logs a hint about the privacy setting.

### `stop()` (lines 152–165)

If an aggregate exists: stop and destroy the IO proc, then destroy the aggregate. Then destroy the tap. Reset IDs and `running`. The order matters: the aggregate references the tap, so it goes first. It is safe to call in any partial state, which is why `fail` uses it.

### `watchOutputDevice()` (lines 168–179)

Installs, once, a property listener block on the system object for `kAudioHardwarePropertyDefaultSystemOutputDevice`, delivered on the main queue. When it fires and the tap is running, it stops, clears `failedAt` and starts again, so the aggregate follows the new output (AirPods connected, speakers changed). The aggregate is clocked by its main sub-device; if that device disappears, the IO proc stops being called and the meters would freeze. The listener is never removed, which is acceptable for an object that lives as long as the app.

### `fail(_:_:)` and `defaultOutputUID()` (lines 181–199)

`fail` is described above and always returns false so callers can `return fail(...)`.

`defaultOutputUID` reads the system object's `kAudioHardwarePropertyDefaultSystemOutputDevice` into an `AudioObjectID`, then that device's `kAudioDevicePropertyDeviceUID`, a `CFString` returned at +1 retain count (a "copy" property), received as `Unmanaged<CFString>?` and converted with `takeRetainedValue()` so ARC balances it. Aggregate dictionaries refer to devices by UID strings, not IDs.

### `process(_:)` (lines 203–232)

Runs on `queue` for every IO cycle.

1. Wraps the input `AudioBufferList` in `UnsafeMutableAudioBufferListPointer` (a Swift collection view over the variable-length C struct) and takes the first buffer's data as `Float` samples. It assumes 32-bit float PCM, the format taps deliver.
2. **Interleaved**: frames = bytes / 4 / channels; for each frame, left is sample `f·ch`, right is `f·ch + 1` (or left again in mono).
3. **Non-interleaved**: frames = bytes / 4 of the first buffer; right comes from the second buffer if present, else left.
4. In both cases it accumulates `l²` and `r²` and pushes the mono average `(l + r)/2` into the FFT block.
5. Computes RMS = √(Σx² / frames) per channel. If either exceeds 1e-5 (−100 dBFS), stamps `lastHeard`. Under `pending`, keeps the maximum RMS seen since the last read.

RMS (root mean square) is the square root of the mean of the squared samples. It tracks perceived loudness and signal power better than the peak sample, which is why VU meters, an averaging instrument, are driven from it.

### `push(_:)` and `analyze()` (lines 234–270)

`push` appends a sample to `mono` and, every 1024 samples (about 21 ms at 48 kHz), resets the counter and calls `analyze()`. Blocks do not overlap.

`analyze()`:

```swift
vDSP.multiply(mono, window, result: &mono)
real.withUnsafeMutableBufferPointer { re in
    imag.withUnsafeMutableBufferPointer { im in
        var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
        mono.withUnsafeBufferPointer { samples in
            samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
            }
        }
        fft.forward(input: split, output: &split)
        vDSP.squareMagnitudes(split, result: &power)
    }
}
```
(`AudioLevels.swift:245–256`)

1. Applies the Hann window in place.
2. Reinterprets the 1024 floats as 512 `DSPComplex` (re, im) pairs and splits them into `real`/`imag` with `vDSP_ctoz`. The input stride of 2 is counted in `Float`s, so it steps one whole (re, im) pair at a time, the standard way to pack a contiguous real signal; the output stride 1 fills `real` and `imag` contiguously. The unsafe pointers are only valid inside the `with…` closures, which is why the code nests them.
3. Runs the forward FFT in place and computes the power of each of the 512 bins.
4. For each band: averages the power over its bins and converts to dB: `10·log10(mean + 1e-12) − 54 + 2.2·i`. The comment explains the 54: a full-scale sine produces about `10·log10((n/2)²) ≈ 54.2 dB` in its peak bin (amplitude N/2 for a real sine through a vDSP real FFT, halved by the Hann window's gain and doubled by vDSP's scaling), so subtracting 54 approximates dBFS. The `2.2·i` dB tilt raises higher bands, because music has much less energy at high frequencies and an untilted display would show only the bass moving.
5. Maps −70…−10 dBFS to 0…1, clamped.
6. Under `pending`, keeps the maximum per band.

The arrays are preallocated, so the only allocation per block is the small `bands` array.

### Threading summary

| Code | Thread |
|---|---|
| `start`, `stop`, `hearing`, `watchOutputDevice` listener, `onPermission` | main |
| `process`, `push`, `analyze` | `queue` (serial, userInteractive) |
| `read` | main (from `NowPlayingSides.stepMeters`) |
| `pending`, `lastHeard` | both, under unfair locks |

Using a dispatch queue instead of the HAL's real-time thread means the analysis code (array access, locks, `log10`) cannot cause audio glitches; it is only measuring.

### Notes and risks

- `AudioLevels.swift:171`, `:191` — uses `kAudioHardwarePropertyDefaultSystemOutputDevice` (the device for alerts and sound effects), not `kAudioHardwarePropertyDefaultOutputDevice` (where Music plays). They are usually the same, but if a user routes sound effects elsewhere, the aggregate is clocked by the wrong device and changing the main output does not trigger a rebuild.
- `AudioLevels.swift:109–115` and `:205`, `:218` — `interleaved` and `bandBins` are written on the main thread in `start()` and read on `queue`. On an output-device restart (`stop()` then `start()`), a block already queued on `queue` from the old IO proc could run concurrently with these writes; `mono`/`filled` are also not reset across restarts.
- `AudioLevels.swift:205` — assumes 32-bit float samples without checking `mFormatID` / `mBitsPerChannel` in the ASBD.
- `AudioLevels.swift:112–113` — at 48 kHz (`binHz` ≈ 46.9 Hz) the 31 Hz and 63 Hz bands both resolve to bin 1 only (`1..<2`), and the 125 Hz band to `1..<4`; the two leftmost spectrum columns show the same data (offset by the 2.2 dB tilt).
- `AudioLevels.swift:96` — the global-tap fallback includes every process, including Himawari's own `ScratchSound` and system sounds.
- `AudioLevels.swift:173` — the property listener is never removed; fine for an app-lifetime object, a leak if instances were ever recreated.
- `AudioLevels.swift:83–84` — "Music isn't running" does not set `failedAt`, so `start()` repeats the PID lookup on every call; this is cheap and intended to retry promptly.
- `AudioLevels.swift:11` — `@unchecked Sendable` hides the main-only properties (`running`, `startedAt`, `failedAt`) from the compiler's checking.

---

## Sources/Himawari/AudioPermission.swift

### Purpose and place in the app

Core Audio process taps require the privacy permission shown in System Settings as "Screen & System Audio Recording ▸ System Audio Recording Only", whose TCC (Transparency, Consent and Control) service name is `kTCCServiceAudioCapture`. macOS offers no public API to query or request it, and a tap made without it does not fail, it delivers silence. This file reads and requests the permission through the private TCC framework, as Apple's own sample code and the open-source AudioCap tool do. Its only caller is `AudioLevels.start()`.

**TCC** is the macOS subsystem (daemon `tccd` plus the private `TCC.framework`) that stores and enforces per-app privacy grants: camera, microphone, screen recording, and so on. `TCCAccessPreflight` checks a service without prompting; `TCCAccessRequest` shows the system prompt if the user has not yet decided and reports the answer.

### Design decisions

- **Runtime lookup.** The functions are looked up with `dlopen`/`dlsym` instead of linking against the private framework. If a future macOS removes them, the lookups return nil and the app treats the permission as granted and lets the tap try; `AudioLevels.hearing` still detects a silent tap.
- **No stored state** beyond lazily initialised statics.

### `AudioPermission` (lines 10–43)

A caseless enum used as a namespace. Its static members are initialised lazily and thread-safely on first access (Swift's guarantee for globals and static stored properties).

| Member | Type | Meaning |
|---|---|---|
| `Status` | enum | `authorized`, `denied`, `unknown` |
| `service` | `CFString` | `"kTCCServiceAudioCapture"` |
| `Preflight` | `@convention(c) (CFString, CFDictionary?) -> Int` | C function type of `TCCAccessPreflight` |
| `Request` | `@convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void` | C function type of `TCCAccessRequest`; the callback parameter bridges to an Objective-C block |
| `tcc` | `UnsafeMutableRawPointer?` | `dlopen` handle for `/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC`, `RTLD_NOW` (resolve all symbols immediately) |
| `preflight` | `Preflight?` | `dlsym(tcc, "TCCAccessPreflight")`, cast with `unsafeBitCast` |
| `requestAccess` | `Request?` | `dlsym(tcc, "TCCAccessRequest")`, cast likewise |

`@convention(c)` declares a Swift function type with the C calling convention, so a raw symbol address from `dlsym` can be reinterpreted as a callable function. `unsafeBitCast` performs that reinterpretation without checks; a wrong signature would be undefined behaviour, which is why the types follow the known prototypes.

#### `status` (lines 21–28)

If `preflight` is missing, returns `.authorized`. Otherwise calls it with no options: 0 → authorized, 1 → denied, anything else (2 in practice: not yet determined) → unknown.

#### `request(_:)` (lines 31–37)

If `requestAccess` is missing, calls `done(true)` asynchronously on the main queue. Otherwise wraps `done` in a `Done` box and calls `TCCAccessRequest`, whose callback arrives on an arbitrary TCC queue; the callback hops to the main queue and calls the box under `onMainActor`. The prompt appears only the first time; later calls report the stored decision.

#### `Done` (lines 39–42)

A tiny `@unchecked Sendable` class holding a `@MainActor (Bool) -> Void`. Swift 6's concurrency checking does not allow a main-actor closure to be captured by the non-isolated TCC callback directly; boxing it in a class asserted as `Sendable` gets it across. This is sound because the box only calls the closure on the main thread.

### Notes and risks

- `AudioPermission.swift:17–19` — relies on private, undocumented TCC symbols and their signatures; a signature change would be undefined behaviour rather than a clean failure (only removal is handled).
- `AudioPermission.swift:22`, `:32` — when the symbols are missing the code assumes permission; combined with taps that deliver silence, the user gets no prompt and only the log hint from `WallpaperManager.checkHearing`.
- `AudioPermission.swift:26` — any value other than 0 or 1 is treated as `.unknown`, which makes `AudioLevels.start()` call `request` (at most once a minute because of `failedAt`).
- Private framework use would block Mac App Store distribution; Himawari is not distributed there.
