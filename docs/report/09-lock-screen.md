# 9 · The lock screen

Himawari plays a video behind the desktop, but the moment the Mac locks, the video is gone: the
lock screen and the login window are drawn by the system (`loginwindow` and the wallpaper agent),
and no third-party app may put a window there. This chapter covers the two ways Himawari still
gets its wallpaper onto that screen:

| Feature (menu item) | File | What appears on the lock screen | Mechanism |
|---|---|---|---|
| Show Wallpaper on Lock Screen (Still) | `Sources/Himawari/LockScreen.swift` | A still frame of the video | Set the macOS wallpaper *picture* with `NSWorkspace.setDesktopImageURL` |
| Moving Lock Screen | `Sources/Himawari/MovingLockScreen.swift` | The video, moving | Replace the video files of the Aerial wallpapers the user picked |

Both are off by default (`Sources/Himawari/Settings.swift:20-21`), because both change system
state outside Himawari's own folder. They are mutually exclusive in practice: turning on Moving Lock
Screen turns the still option off (`AppDelegate.swift:558`).

### Why macOS needs this approach

On macOS, applications draw in windows, and windows belong to a login session. When the screen
locks, the system shows a shield window above everything at a level apps cannot reach, and the
content inside it is drawn by system processes, not by any app. There is no public API for adding
content there; the screen saver API (`ScreenSaverView` bundles) is the closest, and since macOS
Sonoma the lock screen and screen saver are unified around the wallpaper.

What the lock screen *does* show is the user's wallpaper choice, read by the system from its own
settings:

- If the choice is a picture, the lock screen shows that picture. An app can set the picture with
  the public `NSWorkspace.setDesktopImageURL(_:for:options:)`. That is the still option.
- If the choice is one of Apple's **Aerial** videos (added as wallpapers in macOS Sonoma), the
  system plays the Aerial on the lock screen and as the screen saver, then slows it to a stop as
  the desktop appears. Aerials are downloaded into the user's own Library, as ordinary `.mov`
  files that the user can write. Replacing one of those files with the user's own video, encoded
  the way the Aerial player expects, makes the system play that video. That is the moving option.

The second mechanism is not an API. It relies on an undocumented storage layout and on the system
not verifying the files it plays. The risks are discussed at the end of the `MovingLockScreen`
section.

---

## Sources/Himawari/LockScreen.swift

**73 lines.** Puts a still frame of the wallpaper video in place as the macOS desktop picture
(which the lock and login screens show), remembers the previous picture per screen, and puts it
back on request.

**Callers** (all in `AppDelegate`): at launch, if the option is on and our frame is not already
showing (`AppDelegate.swift:51`); when the user chooses a new video (`:453`); and from the menu
toggle (`toggleLockScreen`, `:563-570`), which calls `show` or `restore`.

**Calls:** `AVAssetImageGenerator` (AVFoundation), `NSBitmapImageRep` (AppKit), `NSWorkspace`'s
desktop image API, `UserDefaults`, `FileManager`, and the project's `Log`.

### `LockScreen`

A caseless `@MainActor enum` (a namespace). It holds no instance state; its state lives on disk and
in `UserDefaults`.

| Static property | Type | Meaning |
|---|---|---|
| `folder` | `URL` | `~/Library/Application Support/Himawari/Lock Screen`, where frames are written. |
| `backupKey` | `String` | `"lockScreenOriginalWallpapers"`: a `UserDefaults` key holding `[screen name: original picture path]`. |

#### `show(frameOf:)`

```swift
let pixels = NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max() ?? 2880
Task {
    let asset = AVURLAsset(url: video)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: pixels, height: pixels)
    let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
    let at = CMTime(seconds: duration.isFinite && duration > 0 ? duration * 0.25 : 0, preferredTimescale: 600)
```
(`LockScreen.swift:17-24`)

Steps:

1. **`rememberOriginals()`** first, before anything changes, so the user's own picture is noted.
2. **Target resolution.** For each screen, the longer side in *pixels* (points × backing scale
   factor: 2 on Retina displays), and the maximum over all screens. `maximumSize` on the generator
   is a bounding box: the frame is scaled down to fit inside `pixels × pixels` keeping its aspect,
   and is never scaled up. The fallback 2880 is the long side of a 1440-point Retina display.
3. **`AVAssetImageGenerator`** decodes a single frame from a video. `appliesPreferredTrackTransform`
   applies the track's rotation matrix, so a portrait phone video comes out upright.
4. **Which frame.** A quarter of the way through: the comment explains this avoids fade-ins from
   black at the start. `asset.load(.duration)` is the modern async property loader;
   `CMTimeGetSeconds` converts the `CMTime` (a rational: value / timescale) to seconds. A timescale
   of 600 is the conventional one for video because it divides evenly by 24, 25 and 30 fps.
5. **`generator.image(at:)`** (async) returns the frame and the time it actually used (which may
   differ, since by default the generator snaps to a nearby decodable frame). On failure, log and stop.
6. **Encode to PNG** via `NSBitmapImageRep(cgImage:).representation(using: .png, ...)`. PNG is
   lossless, so the lock screen shows no extra compression artefacts.
7. **Replace old frames.** Create the folder, delete everything in it, and write
   `Himawari-<unix seconds>.png`. The comment gives the reason for a new name each time: macOS caches
   wallpaper pictures by path, so overwriting the same file would leave the old image showing.
8. **Apply** to every screen with `setDesktopImageURL(file, for: screen, options:)`, using
   `.imageScaling = .scaleProportionallyUpOrDown` and `.allowClipping = true`. Together these mean
   "Fill Screen": scale to cover and crop the overflow. Errors are ignored with `try?`.
9. Log.

The `Task {}` inherits the main actor from the enclosing `@MainActor` context, so the code between
`await`s (PNG encoding of a frame of up to about 6K, file writes) runs on the main thread.

#### `isShowing`

True if every screen's current desktop image URL starts with the folder path. Used at launch to
avoid regenerating a frame that is already in place.

#### `restore()`

1. Read the saved dictionary; if there is none, return without changing anything.
2. For each screen, look up its `localizedName` (the display's user-visible name, e.g. "Built-in
   Retina Display"); if this screen was not saved (it was attached later), use any saved value.
   Set that path as the picture with empty options.
3. Remove the backup key and delete the frames folder.

#### `rememberOriginals()` (private)

Only runs if no backup exists yet: the first `show` after the feature is turned on. For each screen
it saves the current picture path, skipping one that is already a Himawari frame. Later calls of
`show` (a new video) keep the original backup, so restore always goes back to the picture from
before the feature was first used.

### State machine

```
             toggle on / launch / new video                toggle off
   ┌───────────┐  rememberOriginals (once)  ┌──────────┐  restore()  ┌───────────┐
   │ user's    │ ─────────────────────────▶ │ Himawari │ ──────────▶ │ user's    │
   │ picture   │  write frame, setDesktop…  │ frame N  │             │ picture   │
   └───────────┘                            └──────────┘             └───────────┘
                                              │   ▲ new video: delete frame N,
                                              └───┘ write frame N+1 (new name)
   UserDefaults["lockScreenOriginalWallpapers"] exists exactly while "Himawari frame" is active.
```

### Notes and risks

- `LockScreen.swift:54-59` — if a screen has no saved entry and the dictionary is empty (every
  screen already showed a Himawari frame when the backup was taken), that screen is skipped, and
  then the folder it points at is deleted (`:59`), leaving a desktop picture whose file no longer
  exists.
- `LockScreen.swift:56` — restore passes empty `options`, so the user's original scaling mode and
  fill colour are not restored. `desktopImageURL(for:)` can only describe a picture file; wallpaper
  choices that are not one picture (Aerials, dynamic wallpapers, shuffling folders, solid colours)
  cannot be captured or restored this way, and the user may end up with a still picture instead.
- `LockScreen.swift:64` — the backup is taken once. If the user changes their wallpaper in System
  Settings while the feature is on and later turns it off, the older picture is put back over their
  newer choice.
- `LockScreen.swift:36` — the file name has one-second resolution; two `show` calls in the same
  second reuse the name, which defeats the cache-busting.
- `LockScreen.swift:29-37` — PNG encoding of a large frame runs on the main actor.
- `AppDelegate.swift:558` — turning on Moving Lock Screen sets `lockScreenMatch = false` without
  calling `LockScreen.restore()`, so the backup key and frames folder stay behind; a later "still"
  toggle on skips `rememberOriginals` because the key exists.

---

## Sources/Himawari/MovingLockScreen.swift

**341 lines.** Makes the user's wallpaper video play, moving, on the lock screen and as the screen
saver, by substituting it for the Aerial videos the user has selected in System Settings. It
contains two types: `MovingLockScreen`, which decides what to replace and manages the files and
state, and `AerialEncoder`, which converts a video into the format the Aerial player expects.

**Callers** (all in `AppDelegate`):

| When | Call | Where |
|---|---|---|
| Launch, option on | `adopt(video:)`, then `apply(video:)` (which only repairs if the video was already converted, and restarts an interrupted conversion), then `startRepairTimer()` | `AppDelegate.swift:52-57` |
| Every 6 hours while on | `repair()` from a repeating `Timer` created by `startRepairTimer()` | `:514-519` |
| New video chosen, option on | `apply(video:)` | `:454` |
| Menu toggle on (after a confirmation alert) | `apply(video:)`; a returned message is shown in an alert with "Open Wallpaper Settings"; on success the repair timer starts | `:521-560` |
| Menu toggle off | invalidates the repair timer, then `restore()` | `:522-528` |
| Menu built | reads `status` to show "Moving Lock Screen (Preparing… 42%)" | `:400-402` |

The confirmation alert (`:530-542`) tells the user what will happen: the Aerials picked in System
Settings are swapped, Apple's videos are kept, conversion takes about five times the Aerial's length
and keeps the processor busy, and macOS decides when the lock screen moves (it may pause on
battery).

### The Aerial store

All paths are relative to `~/Library/Application Support/com.apple.wallpaper`, the per-user folder
of the macOS wallpaper system (Sonoma and later). The code uses two parts of it:

```
~/Library/Application Support/com.apple.wallpaper/
├── Store/
│   └── Index.plist          ← the user's wallpaper and screen-saver choices (read only)
└── aerials/
    └── videos/
        ├── <assetID>.mov     ← downloaded Aerial videos (replaced by Himawari)
        └── …

~/Library/Application Support/Himawari/
├── Aerial Originals/<assetID>.mov   ← Apple's originals, moved here before replacement
├── Moving Lock Screen.mov           ← the "master": user's video, converted, longest length
├── Moving Lock Screen.partial.mov   ← transient: the encode in progress, renamed to the master when done
└── <assetID>.trim.mov               ← transient: a passthrough trim before it is moved in

UserDefaults["movingLockScreenState"] = { video: <source path>, applied: { assetID: byteSize } }
```

An Aerial is identified by an **asset ID** (a UUID string). The file for asset `X` is
`aerials/videos/X.mov`; an Aerial that has not been downloaded has no file (in System Settings it
shows a download arrow, as the error message at `:40` mentions).

### `MovingLockScreen`

**Responsibility.** Find the selected Aerials, convert the user's video once, put a correctly
trimmed copy in place of each selected Aerial, keep Apple's originals, notice if macOS puts an
original back, and undo everything on request.

**Lifecycle.** A singleton (`static let shared`), created on first use by `AppDelegate`, alive for
the life of the app.

**Threading.** `@MainActor`. File operations and state run on the main actor. The conversion runs
inside `AerialEncoder.encode`, a non-isolated `async` function, so under Swift 5.10's rules it runs
on the global concurrent executor, off the main thread; progress callbacks hop back to the main
actor. Export sessions (`AVAssetExportSession`) do their work on AVFoundation's own queues.

| Property | Type | Meaning |
|---|---|---|
| `shared` (static) | `MovingLockScreen` | The singleton. |
| `fm` | `FileManager` | `FileManager.default`. |
| `aerials` | `URL` | `~/Library/Application Support/com.apple.wallpaper`. |
| `home` | `URL` | `~/Library/Application Support/Himawari`. |
| `videos` (computed) | `URL` | `aerials.appending("aerials/videos")`, i.e. `com.apple.wallpaper/aerials/videos`. |
| `originals` (computed) | `URL` | `home/Aerial Originals`. |
| `master` (computed) | `URL` | `home/Moving Lock Screen.mov`. |
| `stateKey` | `String` | `"movingLockScreenState"` in `UserDefaults`. |
| `status` | `String` (`private(set)`) | `""` when idle, `"Preparing… 42%"` while converting. |
| `onStatus` | `(() -> Void)?` | Called when `status` changes. |
| `job` | `Task<Void, Never>?` | The current conversion, cancellable. |

#### `apply(video:)`

```swift
let ids = pickedAerialIDs()
guard !ids.isEmpty else {
    return "Pick an Aerial first: System Settings ▸ Wallpaper, then any video under Landscape, Cityscape, Underwater or Earth (one with no download arrow). Then turn this on again."
}
job?.cancel()
let state = savedState()
if state.video == video.path, !state.applied.isEmpty, Set(state.applied.keys).isSuperset(of: ids) {
    repair() // already made for this video: just make sure it's still in place
    return nil
}
job = Task { await self.convertAndSwap(video: video, targets: await self.aerials(ids)) }
return nil
```
(`MovingLockScreen.swift:38-49`)

Returns a user-facing problem string, or `nil` on success. If no downloaded Aerial is selected
there is nothing to replace. Any running conversion is cancelled. If the saved state says this same
video has already been applied to all the currently selected Aerials (a superset check: extra
applied ones are fine), it only runs `repair()`. Otherwise it starts a conversion task. The task
inherits the main actor; it first resolves the Aerials' durations (`aerials(_:)`), then converts and
swaps. The function returns at once; progress appears through `status`.

#### `restore()`

Cancels the job, then for every `.mov` in `Aerial Originals` deletes the current file of that name
in `videos` and moves the original back. Deletes the master, removes the saved state, clears the
status, logs. It restores *every* backed-up original, not only those in the current state, so
Aerials swapped by an earlier video are also undone.

#### `repair()` — keeping the swap in place

macOS may re-download an Aerial (for example after an update or when it judges the file damaged),
which would silently put Apple's video back. `repair()` detects this by **file size**: the state
remembers the byte size of each file Himawari put in place. For each applied asset:

1. If the current size equals the stored size (or both are missing, −1 vs stored), skip.
2. If the master is missing (a swap made by hand before this feature existed, see `adopt`), start a
   full re-conversion of the saved video for the currently selected Aerials, store it as `job`, and
   stop looking.
3. Otherwise log and start a task that trims the master again for this Aerial's original duration
   and swaps it in.

It runs from `apply` when nothing needs converting (which includes every launch with the option on,
`AppDelegate.swift:55`) and every 6 hours from the timer started by `startRepairTimer()`
(`AppDelegate.swift:514-519`); the timer is invalidated when the option is turned off. Size comparison is cheap (one `stat` per file) and enough to tell Apple's file from
Himawari's, which differ greatly in size.

#### `pickedAerialIDs()` — which Aerials are replaced

```swift
func walk(_ node: Any) {
    if let dict = node as? [String: Any] {
        if dict["Provider"] as? String == "com.apple.wallpaper.choice.aerials",
           let config = dict["Configuration"] as? Data,
           let inner = try? PropertyListSerialization.propertyList(from: config, format: nil) as? [String: Any],
           let id = inner["assetID"] as? String {
            ids.insert(id)
        }
        dict.values.forEach(walk)
    } else if let array = node as? [Any] {
        array.forEach(walk)
    }
}
```
(`MovingLockScreen.swift:93-105`)

`Store/Index.plist` is the wallpaper system's record of what is chosen for each display and Space,
for the desktop and for the idle (screen saver) state. The code does not depend on its exact
structure: it decodes the property list and walks every dictionary and array recursively, looking
for any dictionary whose `Provider` is `com.apple.wallpaper.choice.aerials`. Such a choice carries
its settings as a nested, serialised property list in `Configuration` (a `Data` blob), which is
decoded to find `assetID`. Walking the whole tree picks up Aerials chosen as wallpaper and as
screen saver, on any display or Space. The file is only read, never written; Himawari does not
change the user's choices.

The result is sorted (for stable order) and filtered to IDs that have a file either in `videos`
(downloaded) or in `Aerial Originals` (already swapped earlier and backed up). An Aerial that is
selected but not downloaded is skipped, because there is no file for the system to play.

#### `Aerial`, `aerials(_:)` and `duration(ofOriginal:)`

`struct Aerial { let id: String; let seconds: Double }` pairs an asset with the length of Apple's
video. `aerials(_:)` builds the list, dropping any whose duration is 0 (unreadable).
`duration(ofOriginal:)` reads the duration from the backup if one exists (because once swapped, the
file in `videos` is Himawari's) and otherwise from the file in `videos`, using
`AVURLAsset.load(.duration)`.

Why match Apple's length: each Aerial has its own duration, and the replacement is cut to the same
length (the header comment says the converted video is "each Aerial's own length"). The code's
comments do not say exactly how the system uses the length; matching it keeps the replacement as
close as possible to what the player was built for.

#### `convertAndSwap(video:targets:)`

1. `longest` = the maximum target duration; return if 0.
2. Log; create `Aerial Originals`.
3. Encode the user's video **once** into the master at the longest length with
   `AerialEncoder.encode`. The progress closure wraps each update in `Task { @MainActor in ... }`
   (it is `@Sendable` and called from the encoder's thread), updating `status` as a percentage.
4. On error: log unless the task was cancelled (a cancellation means a newer `apply` or a
   `restore` replaced this one), clear the status, return.
5. Check `Task.isCancelled` after the encode, before each swap and before saving (`:146-153`):
   the comment says a `restore` during conversion must not swap anything back in.
6. For each target, `swap(into:seconds:)`, collecting the resulting byte sizes.
7. Save `{video, applied}`, clear the status, log.

Encoding once and trimming per Aerial is the main design decision. Encoding is the slow part (the
comment estimates about five times real time on Apple silicon; the alert says 20–30 minutes is
common). A user with three Aerials selected would otherwise pay three times. The master is kept
after conversion so that `repair()` can re-create any replacement in seconds without re-encoding.

#### `swap(into:seconds:)` — passthrough trim and replacement

```swift
guard let export = AVAssetExportSession(asset: AVURLAsset(url: master), presetName: AVAssetExportPresetPassthrough) else { return nil }
export.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
do { try await export.export(to: trimmed, as: .mov) } catch {
    Log.write("moving lock screen: trimming for \(id) failed: \(error.localizedDescription)")
    return nil
}
if !fm.fileExists(atPath: backup.path), fm.fileExists(atPath: target.path) {
    try? fm.moveItem(at: target, to: backup) // Apple's original, kept
}
try? fm.removeItem(at: target)
guard (try? fm.moveItem(at: trimmed, to: target)) != nil else { return nil }
return (try? fm.attributesOfItem(atPath: target.path))?[.size] as? Int
```
(`MovingLockScreen.swift:165-176`)

`AVAssetExportSession` with `AVAssetExportPresetPassthrough` copies compressed samples without
decoding or re-encoding, so the HEVC stream, its 240 fps timing and its colour tags are preserved
exactly; only the samples within `timeRange` are written. That makes a trim take seconds instead of
the tens of minutes of an encode. `export(to:as:)` is the async-throwing form of the export call.

The replacement order protects Apple's original: it is moved to the backup folder only if no backup
exists yet. If a backup already exists, the file currently in `videos` is Himawari's from an earlier
swap (or a file macOS re-downloaded, identical to the backup), and is simply deleted. The trimmed
file is written next to the master (same volume as `videos`, so `moveItem` is a rename) and then
moved into place. The function returns the new file's size for the state, or `nil` on failure.

#### State: `savedState()`, `saveState(video:applied:)`, `adopt(video:)`, `setStatus(_:)`

- `savedState()` reads the dictionary at `stateKey`, returning `("", [:])` for missing parts.
- `saveState` writes `{video, applied}`.
- `adopt(video:)`: if no state exists but `Aerial Originals` contains backups, the swap was made by
  hand (before this feature existed, per the comment). It records each backed-up asset with the size
  of the file now in `videos` and the given video path, so `repair()` and `restore()` treat it as
  Himawari's. Called at launch before `repair()`.
- `setStatus(_:)` updates `status` only if it changed and calls `onStatus`.

### `AerialEncoder`

**Responsibility.** Convert any video AVFoundation can read into: 3840×2160, HEVC Main 10, 240
frames per second, no audio, looped to a given number of seconds. A caseless `enum` with static
members; no instance state.

| Static | Value | Meaning |
|---|---|---|
| `fps` | `240` (`Int32`) | Output frame rate. |
| `size` | `3840 × 2160` | Output frame size (4K UHD). |
| `Failure` | `noVideo`, `cannotWrite(String)` | `LocalizedError` with readable descriptions. |

#### Why these parameters

The header comment says the output is "converted to exactly what macOS's Aerial player expects (4K
HEVC, 10-bit, 240 fps, each Aerial's own length)", and that "the 240 fps are for macOS's player,
which counts frames that way". The design matches the format of Apple's downloaded Aerials so the
system player treats the replacement like an original.

- **HEVC** (H.265) and the `hvc1` tag. `AVVideoCodecType.hevc` has the raw value `"hvc1"`, so the
  writer stores the stream under the `hvc1` sample-entry type, in which parameter sets are kept in
  the sample description rather than in the stream. Apple's players require `hvc1` (rather than the
  alternative `hev1`) for HEVC in QuickTime files.
- **Main 10** (`HEVC_Main10_AutoLevel`): the 10-bit profile, with the level chosen by the encoder.
  The input pixels are 8-bit BGRA; the encoder converts them to 10-bit YCbCr.
- **240 fps**: each source frame is written repeatedly, once per 1/240 s that it is on screen. HEVC
  encodes an unchanged frame as a tiny skip frame, so the repeats cost little storage; the comment
  says so ("each source frame repeated as needed, which HEVC stores cheaply").
- **BT.709 colour tags** (primaries, transfer function and matrix): standard HD/SDR colour, so the
  system does not guess.
- **12 Mbit/s average** bit rate; **no audio** track (Aerials are silent).

#### `fillComposition(track:transform:frame:range:)` — the availability branch

```swift
if #available(macOS 26.0, *) {
    var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
    layer.setTransform(transform, at: .zero)
    let instruction = AVVideoCompositionInstruction(configuration: .init(
        layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)], timeRange: range))
    return AVVideoComposition(configuration: .init(frameDuration: frame, instructions: [instruction], renderSize: size))
}
let composition = AVMutableVideoComposition()
composition.renderSize = size
composition.frameDuration = frame
```
(`MovingLockScreen.swift:232-241`)

An **AVVideoComposition** tells AVFoundation how to render video frames: an output size
(`renderSize`), a frame rate (`frameDuration`), and *instructions*, each covering a time range and
listing *layer instructions* that place a source track with an affine transform. Here there is one
instruction for the whole source, with one layer that applies the aspect-fill transform.

Historically one built compositions with the mutable classes `AVMutableVideoComposition`,
`AVMutableVideoCompositionInstruction` and `AVMutableVideoCompositionLayerInstruction`. The comment
records that macOS 26 replaced these with value-type `Configuration` structs passed to immutable
initialisers. Himawari still supports macOS 14.4
(`Package.swift:8`), so it uses `#available(macOS 26.0, *)`: the new API where available (avoiding
deprecation warnings and following Apple's direction), the mutable classes otherwise. Both branches
build the same composition.

#### `encode(_:to:seconds:progress:)`

**Inputs:** source URL, output URL, target seconds, a `@Sendable` progress callback (0…1).
**Output:** a finished `.mov` at `output`, or a thrown error. Honours task cancellation.

**1. Inspect the source** (`:252-259`). Load the first video track (else `Failure.noVideo`), its
`naturalSize` (the stored frame size, before rotation), its `preferredTransform` (rotation/flip
matrix), the asset duration (a zero duration also throws `noVideo`), and the nominal frame rate. `frameSeconds` is one source frame's
duration, assuming 30 fps if the rate is unknown.

**2. Aspect-fill transform** (`:262-267`). Apply the preferred transform to the natural size to get
the displayed size (`CGSize.applying` ignores translation, and a rotation can make components
negative, hence `abs`). `scale` is the larger of the two ratios to 3840×2160, so the frame covers
the output; the excess is cropped. The final transform is: the track's own transform, then the
scale, then a translation that centres the scaled frame (the translation is negative on the
overflowing axis).

**3. Writer setup** (`:269-291`). The writer does not write to `output` directly but to a sibling
`<name>.partial.mov` (deleting any leftover first). The comment explains why: a failed or cancelled
conversion must not destroy the previous good master, because repairs trim from it. It creates an
`AVAssetWriter` (a QuickTime file) with one `AVAssetWriterInput` for video with the settings described above
(`AVVideoExpectedSourceFrameRateKey: 240` hints the encoder's rate control). `expectsMediaDataInRealTime
= false` tells the writer to optimise for throughput, not for live capture. An
`AVAssetWriterInputPixelBufferAdaptor` accepts `CVPixelBuffer`s with explicit presentation times;
its attributes declare 32BGRA 3840×2160 buffers. `canAdd`, `startWriting` and
`startSession(atSourceTime: .zero)` start the file; failures become `Failure.cannotWrite`.

**4. Looping passes** (`:293-328`).

```swift
while written < total, let sample = out.copyNextSampleBuffer() {
    try Task.checkCancellation()
    guard let frame = CMSampleBufferGetImageBuffer(sample) else { continue }
    let showsUntil = passStart + CMSampleBufferGetPresentationTimeStamp(sample).seconds + frameSeconds
    // Repeat this frame for every 1/240 s it's on screen.
    while written < total, Double(written) / Double(fps) < showsUntil {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        guard adaptor.append(frame, withPresentationTime: CMTime(value: CMTimeValue(written), timescale: fps)) else {
            throw Failure.cannotWrite(writer.error?.localizedDescription ?? "the encoder stopped")
        }
        written += 1
        if written % 480 == 0 { progress(Double(written) / Double(total)) }
    }
}
```
(`MovingLockScreen.swift:309-321`)

`total = seconds × 240` output frames. The outer loop makes repeated passes through the source until
enough frames are written; this is how a short clip is looped to an Aerial's length. Each pass
creates a new `AVAssetReader` (a reader cannot be rewound) with an
`AVAssetReaderVideoCompositionOutput`, which decodes the track *through the video composition*, so
every sample it returns is already a 3840×2160 BGRA frame, scaled and cropped. Rendering happens in
AVFoundation, using the GPU.

Within a pass, each decoded frame is "on screen" until `passStart + PTS + frameSeconds`, where PTS
is its presentation time in the source. The inner loop appends the same pixel buffer at output
times `written / 240` for as long as those times fall before that point. This is a
frame-rate conversion by sample-and-hold: a 30 fps source gives each frame 8 consecutive output
frames, a 24 fps source 10, a 60 fps source 4. Output timestamps are exact integers on a 240-unit
timescale, so there is no rounding drift. After the pass the reader's status is checked and the reader cancelled. If the reader failed, or
the pass appended no frames at all (`written == before`), the encode throws (`:323-326`) instead of
looping forever on a source that yields nothing; otherwise `passStart` advances by the source
duration.

**Back-pressure.** The hardware encoder accepts frames only as fast as it can compress them.
`isReadyForMoreMediaData` reports whether the input can take another; the loop polls it every 5 ms
with `Task.sleep`, which suspends without blocking a thread and is also a cancellation point.
(`requestMediaDataWhenReady(on:using:)` is the callback alternative; polling keeps the code linear
inside one async function.) `Task.checkCancellation()` at both loop levels lets a new `apply` or a
`restore` stop the encode within a frame. Progress is reported every 480 frames (2 s of output).

**5. Finish** (`:329-339`). `markAsFinished`, `await finishWriting()`, check `status == .completed`
(else throw). The whole writing phase is wrapped in `do`/`catch`: on any error (including
cancellation) the writer is cancelled if still writing, the partial file deleted, and the error
rethrown. On success the old master is deleted and the partial file is moved into its place, then
progress 1.0 is reported.

### Data flow

```
user's video ──AVAssetReader + VideoComposition (fill 3840×2160, BGRA)──▶ frames
     ▲  re-read each pass (loop)                                          │ repeat ×(240/src fps)
     │                                                                    ▼
     └──────────── until seconds×240 frames ◀── AVAssetWriter (HEVC Main10 hvc1, 240 fps)
                                                         │
                                                         ▼
                          Moving Lock Screen.partial.mov ──rename when complete──▶
                                       Himawari/Moving Lock Screen.mov  (master, longest Aerial)
                                                         │ AVAssetExportSession passthrough
                                    ┌────────────────────┼────────────────────┐
                                    ▼                    ▼                    ▼
                           A.trim.mov (lenA)    B.trim.mov (lenB)    …  moved into
                       com.apple.wallpaper/aerials/videos/<id>.mov  (originals → Aerial Originals/)
```

### Status in the menu

`status` is `"Preparing… N%"` while encoding and `""` otherwise. The menu is rebuilt every time it
opens (`AppDelegate` is the menu's delegate), so it reads the value fresh:
"Moving Lock Screen (Preparing… 42%)". `onStatus` would allow a live update, but no code assigns it.

### Risks of the approach

- **Undocumented layout.** The store path, the `Index.plist` structure (`Provider`,
  `Configuration`, `assetID`) and the `aerials/videos/<id>.mov` naming are private to macOS.
  A future release can rename or restructure them; then `pickedAerialIDs()` returns nothing and the
  feature reports "Pick an Aerial first".
- **File-format expectations.** If the system player's expectations change (resolution, frame rate,
  HDR), the replacement may stop playing or look wrong. Nothing in the code verifies that the system
  actually plays the file.
- **Integrity checks.** The approach works only while macOS does not verify downloaded Aerials
  against a hash or signature. If it starts doing so, it may re-download them (which `repair()`
  would then fight every 6 hours) or refuse to play them.
- **System-owned files.** Himawari moves and deletes files in a folder it does not own. A crash
  between moving the original out and moving the replacement in leaves an Aerial missing until the
  next swap or `restore()`.
- **Cost.** The encode is long and CPU/GPU-heavy, and writes a large file (12 Mbit/s for the
  longest Aerial's length, plus one trimmed copy per selected Aerial).
- **Uninstalling.** If Himawari is deleted while the feature is on, Apple's originals stay in
  `~/Library/Application Support/Himawari/Aerial Originals` and the Aerials keep playing the user's
  video until macOS re-downloads them.
- **System control.** As the alert says, macOS decides when the lock screen animates (it may not on
  battery).

### Notes and risks

- `MovingLockScreen.swift:80` — the re-swap task started by `repair()` is not stored in `job`, so
  `restore()` cannot cancel it; a repair finishing just after a restore could move a replacement back
  in.
- `MovingLockScreen.swift:150-151,171-175` — the cancellation checks run *between* swaps. A swap
  already in flight when `restore()` runs completes afterwards: by then the backup has been moved
  back, so it backs up Apple's file again and installs the replacement, and the state is not saved.
  The Aerial stays swapped with no record of it until the next `restore()` (which still finds the
  backup).
- `MovingLockScreen.swift:80,176` — a repair re-swap does not update the stored byte size; if a new
  passthrough export differs in size from the first (e.g. metadata), every later `repair()` swaps
  again.
- `MovingLockScreen.swift:74-77` — when the master is missing, `repair()` re-converts `state.video`
  even if that path no longer exists; the encode then fails and only the log says so.
- `MovingLockScreen.swift:31,206` — `onStatus` is never assigned, so the status only updates when the
  menu is reopened.
- `MovingLockScreen.swift:148-154` — when a new video is applied, `applied` is replaced by the current
  targets only; Aerials that were swapped earlier but are no longer selected keep the old video and
  are no longer checked by `repair()` (though `restore()` still restores them).
- `MovingLockScreen.swift:271` — a crash or force-quit mid-encode leaves
  `Moving Lock Screen.partial.mov` (several GB possible) until the next encode deletes it;
  `restore()` does not remove it.
- `MovingLockScreen.swift:315` — back-pressure is handled by polling every 5 ms rather than with
  `requestMediaDataWhenReady`.
- `MovingLockScreen.swift:309` — `copyNextSampleBuffer()` blocks the cooperative-pool thread it runs
  on while decoding; acceptable for one job, but it holds a Swift concurrency thread for the duration.
