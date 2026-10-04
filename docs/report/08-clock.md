# 8 · The desktop clock and its contrast

Himawari draws a large clock on the desktop, in the style of the desktop clocks of GNOME and KDE:
glowing text with no panel behind it. The clock is not part of the main Himawari process. It is
a second executable, `HimawariClock`, packaged as a helper app at
`Himawari.app/Contents/Helpers/Desktop Clock.app` (see `build.sh:75-78`). Himawari starts it at
launch and stops it at quit, and the two talk only through shared preferences and macOS
*distributed notifications*.

The clock is also the one part of the app that has to adapt its look to what is behind it. White
text disappears over a bright sky; navy text disappears over a night scene. So the chapter covers
two subjects that live in different processes:

1. the clock itself (`Sources/HimawariClock/*`) and the code in Himawari that runs it
   (`Sources/Himawari/ClockHelper.swift`);
2. the contrast protocol: Himawari measures the brightness of whatever it is showing behind the
   clock and sends the clock a reading (`Sources/Himawari/ToneReporter.swift`,
   `Sources/HimawariKit/WallpaperTone.swift`).

Two shared files close the chapter: `Sources/HimawariKit/Hotkeys.swift` (the system-wide
shortcut that shows the clock again, plus some code inherited from an earlier project) and
`Sources/HimawariKit/AeroStyle.swift` (the shared "Frutiger Aero" font and colours).

The overall picture:

```
            Himawari.app (main process)                     Desktop Clock.app (helper)
 ┌──────────────────────────────────────────┐        ┌───────────────────────────────────┐
 │ AppDelegate                              │ spawn  │ main.swift: runBackgroundService  │
 │   ClockHelper.start() ───────────────────┼───────▶│   --parent <pid>  (watchdog 3 s)  │
 │   HotKey ⌃⌥⌘C → Settings.showClock.toggle│        │                                   │
 │                                          │        │ DesktopClock                      │
 │ WallpaperManager                         │        │   DesktopWindow (level +22)       │
 │   sampleTone / sceneTone / youTubeTone   │        │   ClockView ← ClockTicker         │
 │        │                                 │        │           ← ClockTone (dark/busy) │
 │        ▼                                 │        │                                   │
 │   ToneReporter ── WallpaperTone.post ────┼─DNC──▶ │ observeReadings → updateTone()    │
 │        ▲                                 │ reading│                                   │
 │        └── onReadingRequest ◀────────────┼─DNC─── │ requestReading(region)            │
 │                                          │ request│                                   │
 │  shared prefs domain local.dhairyabhatia.desktop  ◀──── Settings (both read & write)   │
 │  "…desktop.changed" broadcast  ◀──────────────────────▶ Settings.onChange → refresh() │
 └──────────────────────────────────────────┘        └───────────────────────────────────┘
   DNC = DistributedNotificationCenter
```

---

## Sources/HimawariClock/main.swift

**22 lines.** The entry point of the clock helper. It is a top-level Swift script (no
`@main` type): the code at file scope runs when the process starts.

### Role and design

The file does four things inside the closure handed to `runBackgroundService`
(`Sources/HimawariKit/DesktopWindow.swift:55-71`):

1. creates the single `DesktopClock` and calls `refresh()` once so the clock appears;
2. registers `Settings.onChange { clock.refresh() }`, so that any process that writes a setting
   and calls `Settings.broadcastChange()` causes the clock to re-read and re-draw;
3. observes `NSApplication.didChangeScreenParametersNotification` (resolution change, display
   attached or removed, Dock moved) and calls `refresh()`;
4. if the command line contains `--parent <pid>`, starts a parent watchdog.

`runBackgroundService` is shared code (covered with `DesktopWindow` elsewhere in the report). In
short, it sets the activation policy to `.accessory` (no Dock icon, no menu bar; the helper's
`Info.plist` also sets `LSUIElement`), turns `SIGTERM` into a dispatch signal source so the
process can exit cleanly with status 0, calls the `make` closure, and keeps its result alive with
`withExtendedLifetime` while `NSApplication.run()` spins the main run loop. Returning `clock` from
the closure is what keeps the `DesktopClock` object alive: nothing else holds a strong reference
to it.

### The parent watchdog

```swift
if let i = CommandLine.arguments.firstIndex(of: "--parent"), i + 1 < CommandLine.arguments.count,
   let parent = pid_t(CommandLine.arguments[i + 1]) {
    Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
        if kill(parent, 0) != 0 { exit(0) }
    }.tolerance = 1
}
```
(`Sources/HimawariClock/main.swift:15-20`)

`kill(pid, 0)` is the POSIX idiom for "does this process exist?": signal number 0 sends nothing
but performs the existence and permission checks. It returns 0 if the process exists and −1
otherwise (`ESRCH` for "no such process"). Every 3 seconds (with 1 s of tolerance, which lets
macOS coalesce the wake-up with other timers to save power) the clock checks whether Himawari
still exists and exits if not. This covers the case `ClockHelper` cannot: Himawari crashing or
being force-quit, so its `applicationWillTerminate` never runs and never sends `SIGTERM`.

The watchdog is only installed when `--parent` is present. Run by hand (for debugging) the clock
lives until killed.

**Why a separate process at all?** The comment at `ClockHelper.swift:4-7` gives the reason:
fault isolation. A crash in the clock (SwiftUI, fonts, timers) does not take down the wallpaper,
and vice versa. Historically the clock was also a separate launchd service of a "Desktop Shell"
project (see `retireOldService` below), so the split already existed.

### Notes and risks

- `main.swift:18` — `kill(parent, 0)` can, in principle, succeed for an unrelated process that
  reused Himawari's pid after Himawari died; the clock would then linger until that process
  exits. PID reuse within a few seconds is unlikely on macOS but not impossible.
- `main.swift:10-14` — the screen-parameters observer is never removed; that is fine because it
  lives as long as the process.

---

## Sources/HimawariClock/DesktopClock.swift

**278 lines.** The clock's controller and its SwiftUI views: the `DesktopClock` class that owns
the window, the `ClockView` that draws the time, the `ClockInk` modifier that chooses colours and
glows, the `ClockTone` observable that carries the contrast decision, and the transient
`ClockHiddenHint`.

It is called by `main.swift` (creation and `refresh()`), and it calls `ClockFace`/`ClockTicker`
(`ClockFace.swift`), `WallpaperTone` (readings and the fallback grid), `DesktopWindow` and
`DesktopLayer` (`HimawariKit/DesktopWindow.swift`), `DesktopLayout.freeArea`
(`HimawariKit/DesktopLayout.swift`), and the shared `Settings`.

### Background: AppKit window levels and the desktop

Every macOS window has a *level*, an integer; higher levels draw above lower ones. The desktop
picture sits at `CGWindowLevelForKey(.desktopWindow)`. Finder draws the desktop icons in a
full-screen window about 20 levels higher, and that window takes every click on the empty
desktop. Himawari's `DesktopLayer` (`DesktopWindow.swift:8-17`) expresses its windows as offsets
from the desktop level: `video = 1`, `decorations = 2`, `folders = 22`, `overlay = 23`. The clock
uses `DesktopLayer.folders` (+22): above Finder's icon window, so that the clock can receive
clicks, yet far below normal application windows, which cover it.

`DesktopWindow` is a borderless, transparent `NSWindow` with
`collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]`: it shows
on every Space, does not slide during Space switches or Mission Control, is skipped by ⌘\`
window cycling, and never enters full screen. `interactive: false` sets `ignoresMouseEvents`, so
clicks go straight through. Its `host(_:)` puts a SwiftUI view into a `FirstClickHostingView` (an
`NSHostingView` subclass whose `acceptsFirstMouse` returns `true`, so the first click on an
inactive app is delivered rather than only activating it) and sizes the window to the view's
`fittingSize`.

### `DesktopClock`

**Responsibility.** Decide whether the clock is visible, build and place its window, keep the
ticker running at the right rhythm, and turn brightness readings into a light/dark text decision.

**Lifecycle.** Exactly one instance, created by `main.swift:7` and kept alive by
`runBackgroundService` for the whole life of the helper process.

**Threading.** `@MainActor`. All callbacks it receives (distributed notifications, system clock
notifications, dispatch timers) are delivered on the main queue and enter main-actor code through
the project's `onMainActor` helper (`HimawariKit/MainThread.swift:8-13`), which asserts
`Thread.isMainThread` and then calls the closure as if it were main-actor isolated. The project
uses this instead of `MainActor.assumeIsolated` because the latter crashed in
`swift_task_isMainExecutor` from plain timers (see the comment in that file).

**Stored state.**

| Property | Type | Meaning |
|---|---|---|
| `window` | `DesktopWindow?` | The clock's window, or `nil` while hidden. Rebuilt on every effective `refresh()`. |
| `tone` | `ClockTone` (let) | Shared observable read by the view: `dark` text? `busy` background? |
| `ticker` | `ClockTicker` (let) | Publishes `now` at each change of the displayed time. |
| `reading` | `ToneReading?` | The latest brightness reading (from Himawari, or from the macOS wallpaper at startup). |
| `lastLogged` | `Double?` | Brightness at the last log line; only used as "has anything been logged yet". |
| `placed` | `String?` | Signature of the settings and free area currently on screen; `nil` forces a rebuild. |
| `hint` | `DesktopWindow?` | The "Clock hidden" note while it is visible. |

#### `init()`

Three groups of work (`DesktopClock.swift:17-38`):

1. **Readings from Himawari.** `WallpaperTone.observeReadings` registers for the reading
   notification. For each reading it stores it, and if `reading.focus == nil` (a reading without
   a measurement of the clock's own spot) it calls `tellHimawariWhereWeAre()`. That case means
   Himawari started after the clock, or restarted, and does not yet know where the clock is; the
   clock's answer is to re-send its location. Then `updateTone()`. The closure captures
   `[weak self]`, though for a process-lifetime object this is defensive rather than necessary.
2. **Clock resynchronisation.** One closure `resync` is registered for
   `.NSSystemClockDidChange` (the time was set by hand or by network time),
   `.NSSystemTimeZoneDidChange`, and `NSWorkspace.didWakeNotification` (posted on the workspace's
   own notification centre, not the default one). It sets `placed = nil` and calls `refresh()`,
   which forces a full rebuild: a fresh window and a fresh `ticker.run(...)` aimed at the next
   boundary computed from the *new* time. Without this, a dispatch timer scheduled for "60 s from
   now" before a 1-hour clock change would show the wrong minute until it fired. The closure is
   typed `@Sendable (Notification) -> Void` to satisfy the `addObserver(forName:object:queue:using:)`
   signature under strict concurrency, and it hops through `DispatchQueue.main.async` before
   entering `onMainActor`.
3. **Fallback reading.** If the macOS wallpaper picture of the main screen can be loaded,
   `WallpaperTone.systemWallpaperGrid(for:)` measures it and the result becomes the initial
   `reading` (grid only, no focus). This gives sensible contrast immediately, and permanently if
   Himawari never answers.

#### `tellHimawariWhereWeAre()`

Converts the window frame, inset by 24 points on each side (the `padding(24)` that `ClockView`
adds for the glow), into fractions of the screen with y running down
(`WallpaperTone.fraction(of:on:)`) and posts it as a reading request. The inset makes Himawari
measure only the area under the glyphs, not the transparent margin. Does nothing if there is no
window.

#### `updateTone()` — choosing light or dark text

```swift
let b = reading.focus ?? WallpaperTone.brightness(of: reading.grid, under: window.frame, on: screen)
let wasDark = tone.dark, wasBusy = tone.busy
if tone.dark && b < 0.5 { tone.dark = false } else if !tone.dark && b > 0.6 { tone.dark = true }
// A busy picture behind it (album art, a music video): stronger contrast.
if let spread = reading.spread {
    if tone.busy && spread < 0.13 { tone.busy = false } else if !tone.busy && spread > 0.19 { tone.busy = true }
}
```
(`DesktopClock.swift:49-55`)

The brightness `b` is Himawari's precise `focus` value when available (the mean of 200 samples
under the clock); otherwise it is the average of the 8×8 grid cells that the window frame
overlaps.

Both decisions use **hysteresis**, a dead band between two thresholds, so that a value hovering
around one threshold does not make the text flip every frame:

```
  dark text?                     busy?
  false ──b > 0.6──▶ true        false ──spread > 0.19──▶ true
  false ◀──b < 0.5── true        false ◀──spread < 0.13── true
  (0.5…0.6: keep current)        (0.13…0.19: keep current)
```

`spread` is the standard deviation of brightness behind the clock (0…0.5). A high spread means a
busy picture such as album art or a music video, where neither text colour is safe everywhere;
`busy` switches on an extra wide halo in `ClockInk`. When `spread` is `nil` (fallback grid),
`busy` is left as is.

A log line is printed when either flag changes, or once at the start (`lastLogged == nil`). The
helper's stdout is inherited from Himawari's process (see `ClockHelper`), so these lines appear
wherever Himawari's output goes; `fflush` makes them appear immediately rather than when the
buffer fills.

Because `tone` is an `ObservableObject` and `ClockView` observes it, changing the flags re-renders
the view, and the `.animation(..., value: tone.dark)` modifiers make the switch a 0.8 s cross-fade.

#### `refresh()` — show, hide, or move

The function is called for every settings broadcast from any process, for every screen change,
and on resync. Most broadcasts concern other things (volume, bar fill), so it first builds a
**signature** of everything that affects the clock:

```swift
let signature = [String(s.showClock), s.clockFormat.rawValue, String(s.clockSeconds), String(s.clockShowDate),
                 s.clockSize.rawValue, s.clockStyle.rawValue, s.clockPosition.rawValue,
                 area.map { NSStringFromRect($0) } ?? ""].joined(separator: "|")
if signature == placed { return }
```
(`DesktopClock.swift:70-73`)

`area` is `DesktopLayout.freeArea(of: NSScreen.main)`: the screen's `visibleFrame` (minus menu bar
and Dock) minus the strips that other Himawari components have reserved in shared preferences
(widgets, folders, taskbar). Including it in the signature means the clock moves when, for
example, a folder column appears.

If the signature differs, the function rebuilds from scratch:

1. Remember the old frame, `orderOut` the old window and drop it.
2. If `showClock` is false (or there is no main screen): stop the ticker, and if a window had been
   visible, show the "Clock hidden" hint where it was. Return.
3. Ask `ClockFace.ticks(format:seconds:)` for the anchor and step and start the ticker.
4. Create a `DesktopWindow(layer: DesktopLayer.folders, interactive: true)` and host a new
   `ClockView` with the current settings, the shared `tone` and `ticker`. `host` sizes the window
   to the view.
5. Place it with `origin(for:size:in:screenCenter:)` and `orderFrontRegardless()` (show it without
   activating the app, which an accessory app should not do).
6. `tellHimawariWhereWeAre()` and `updateTone()` with the existing reading, so contrast is right
   on the first frame.

Rebuilding the window rather than mutating it keeps the code short: size, fonts and position all
follow from one construction. The cost is a brief disappearance on each change, which only happens
on user actions.

#### `showHiddenHint(at:)`

A non-interactive window at the same level, hosting `ClockHiddenHint`, centred on the old clock's
frame. It fades in over 0.3 s (`NSAnimationContext` with `animator().alphaValue`), stays 4.5 s,
fades out over 0.6 s, and in the completion handler is ordered out; `self.hint` is cleared only if
it still refers to this window (`===`), so a second, newer hint is not lost. The delayed block
captures both `self` and `w` weakly. Note that `hint` holds the window strongly; the weak capture
of `w` only matters if `hint` was replaced in the meantime.

#### `origin(for:size:in:screenCenter:)`

A static pure function that turns a `ClockPosition` into a window origin in AppKit screen
coordinates (origin at the bottom-left, y up).

| Position | x | y |
|---|---|---|
| `.topLeft` / `.bottomLeft` | `area.minX + 24` | top: `area.maxY − h − 24`; bottom: `area.minY + 24` |
| `.topRight` / `.bottomRight` | `area.maxX − w − 24` | as above |
| `.topCenter` / `.center` | `screenCenter − w/2`, clamped into `[area.minX, area.maxX − w]` | top: as above; center: `area.midY − h/2` |

Centred positions use the middle of the *screen* (`visibleFrame.midX`), not of the free area.
The free area is usually lopsided (widgets on one side, folders on the other), and a clock centred
in it would look off-centre on the screen. The clamp moves it only as far as needed to stay out of
reserved strips. The 24-point margin adds to the view's own 24-point padding, so the glyphs sit
about 48 points from the free area's edge.

### `ClockHiddenHint`

A SwiftUI `View`: two lines of white text ("Clock hidden" in the Aero font, 17 pt semibold, and
"Bring it back with ⌃⌥⌘C, or the Himawari menu ▸ Show Desktop Clock", 13 pt) on a 55 % black
rounded rectangle. It exists because once the clock is hidden it has no surface left to right-click,
so the user needs to be told how to get it back. No state.

### `ClockTone`

A `@MainActor final class ClockTone: ObservableObject` with two `@Published` booleans:

| Property | Type | Meaning |
|---|---|---|
| `dark` | `Bool` | Use dark (navy) text: the background is bright. |
| `busy` | `Bool` | The background is busy: add a strong halo. |

Owned by `DesktopClock` (a `let`), passed into every `ClockView` it creates; so it survives window
rebuilds and the view starts with the current decision.

### `ClockView`

**Responsibility.** Draw the time (and optional date or caption) in the chosen format, size and
style; cycle formats on left-click; show the options menu on right-click.

**Stored state** (all `let` except the two observed objects; a new `ClockView` is built on each
rebuild):

| Property | Type | Meaning |
|---|---|---|
| `format` | `ClockFormat` | 12-Hour, 24-Hour, Swatch Internet Time, French Decimal Time, In Words. |
| `showSeconds` | `Bool` | Include seconds (or centibeats / decimal seconds). |
| `showDate` | `Bool` | Show the caption line under the time. |
| `size` | `ClockSize` | Small 0.65×, Medium 1×, Large 1.35× (`Settings.swift:186-189`). |
| `style` | `ClockStyle` | Aero Glass, Fluorescent Display, Rounded, Serif. |
| `tone` | `@ObservedObject ClockTone` | Contrast decision. |
| `ticker` | `@ObservedObject ClockTicker` | Supplies `now`; each change re-evaluates `body`. |

#### `body`

1. `ClockFace.parts(ticker.now, format:seconds:)` yields `(main, small, caption)`.
2. The main size is 110 pt × scale, or 58 pt × scale for words (sentences are long).
3. An `HStack` aligned on `.firstTextBaseline` holds the main text and, if non-empty, the small
   suffix (" AM") at a third of the size, so "AM" sits on the same baseline as the digits. Words
   use a plain `Text`; every other format uses `FixedWidthDigits` so that changing digits do not
   shift the line.
4. The line gets `ClockInk` at opacity 0.8.
5. If `showDate`, a caption line at 26 pt × scale: the format's own caption (Swatch / Decimal
   formats supply one) or the date formatted as `weekday(.wide).day().month(.wide)`, e.g.
   "Sunday, October 4" in an English (US) locale. Ink opacity 0.85.
6. Two `.animation(.easeInOut(duration: 0.8), value:)` modifiers animate tone changes only;
   the ticking itself is not animated.
7. `.padding(24)` gives the shadows room inside the window; the window has no clipping margin
   of its own.
8. `.contentShape(Rectangle())` makes the whole padded rectangle clickable, not only the glyph
   pixels (SwiftUI otherwise hit-tests text by its shape).
9. `.onTapGesture { change { $0.clockFormat = format.next } }` — left-click cycles to the next
   format (`ClockFormat.next` wraps through `allCases`, `Settings.swift:180-183`).
10. `.contextMenu { options }` — on macOS, SwiftUI's `contextMenu` appears on right-click
    (or control-click).

**How a click takes effect.** `change` writes the setting into the shared domain and broadcasts.
The clock process itself is a listener: 0.15 s later (the debounce in `Settings.onChange`)
`refresh()` sees a new signature and rebuilds the window with the new format. The view never
mutates its own `format`; the settings store is the single source of truth, which also keeps
Himawari's menu checkmarks in sync.

#### `nsFont(_:weight:)`

Returns an `NSFont` for the current style:

| Style | Font |
|---|---|
| `.aero` | `aeroNSFont` (Frutiger → … → Avenir Next → system; see AeroStyle) |
| `.vfd` | `NSFont.monospacedSystemFont` (SF Mono) — evokes a vacuum-fluorescent display |
| `.rounded` | system font with `NSFontDescriptor.SystemDesign.rounded` (SF Pro Rounded) |
| `.serif` | system font with `.serif` design (New York) |

The nested `designed(_:)` falls back to the plain system font if the descriptor cannot be
converted. An `NSFont` (not a SwiftUI `Font`) is used because `FixedWidthDigits` needs to measure
glyph widths with `NSAttributedString.size()`; the same font is wrapped with `Font(nsFont)` for
`Text`.

#### `options` — the right-click menu

A `@ViewBuilder` producing: a Format picker (one item per `ClockFormat`), "Show Seconds" and "Show
Date" toggles, a divider, Size / Style / Position pickers, a divider, and "Hide Clock (⌃⌥⌘C Shows
It Again)". In a context menu, SwiftUI renders each `Picker` as a submenu with a checkmark on the
selected value and each `Toggle` as a checkable item.

#### `binding(_:)` and `change(_:)`

```swift
private func binding<T>(_ key: ReferenceWritableKeyPath<HimawariKit.Settings, T>) -> Binding<T> {
    Binding(get: { HimawariKit.Settings.shared[keyPath: key] }, set: { value in change { $0[keyPath: key] = value } })
}

private func change(_ edit: (HimawariKit.Settings) -> Void) {
    edit(HimawariKit.Settings.shared)
    HimawariKit.Settings.broadcastChange()
}
```
(`DesktopClock.swift:239-246`)

A `ReferenceWritableKeyPath` is needed because `Settings` is a class; writing through the key
path calls the property's setter, which writes `UserDefaults`. The getter goes back to the store
each time (the store's getters call `synchronize()` to pick up writes from Himawari). The type is
spelled `HimawariKit.Settings` because the clock target also imports SwiftUI, which has its own
`Settings` scene type; the module prefix resolves the ambiguity.

### `ClockInk` (private)

A `ViewModifier` that paints text and stacks shadows. In SwiftUI each `.shadow` is applied to the
already-shadowed result, so stacking several gives a layered glow.

| Mode | Fill | Shadows |
|---|---|---|
| `vfd` | cyan `(0.45, 0.97, 1.0)` at opacity + 0.1 | cyan glow r=8 at 0.8; black r=3 at 0.8 if dark or busy, else 0.45 |
| `dark` (bright background) | navy `(0.05, 0.12, 0.25)` at `opacity` | white r=10 at 0.85; white r=2 at 0.6; white r=18 at 0.9 when busy, else 0 |
| light (dark background) | white at `opacity` | `aeroGlow` r=10 at 0.6; black r=3 y=1 at 0.55; black r=16 at 0.75 when busy, else 0 |

The fluorescent style ignores the dark/light choice for its fill (a VFD is always cyan) and only
strengthens its dark halo. Keeping the busy shadow present at opacity 0, rather than adding it
conditionally, keeps the view structure identical in both states, so SwiftUI can animate the
opacity instead of inserting and removing a view.

### Notes and risks

- `DesktopClock.swift:41-43,88-92` — the window is sized once, from the view's `fittingSize` at
  creation, and positioned once. Formats whose text width changes over time (In Words: "noon"
  vs "twenty-five past eleven"; 12-hour "9:59" vs "10:00"; the date caption from day to day) are
  not re-measured or re-centred by `DesktopClock` until something triggers a rebuild. Whether the
  window grows depends on `NSHostingView`'s default sizing behaviour; in any case the computed
  centring and the region sent to Himawari can go stale.
- `DesktopClock.swift:201,243-246` — every left-click destroys and rebuilds the window (via the
  broadcast → `refresh()` round trip), so the clock blinks on each format change.
- `DesktopClock.swift:15,60` — `lastLogged` stores a value that is never read except as a
  nil check.
- `DesktopWindow.swift:10` — the comment says the clock uses the click-through `decorations`
  layer, but the clock now uses `folders` with `interactive: true` (`DesktopClock.swift:87`);
  the comment is stale.
- `DesktopClock.swift:43` — the 24-point inset is a copy of `ClockView`'s `padding(24)`
  (`:199`); changing one without the other makes Himawari measure the wrong area.

---

## Sources/HimawariClock/ClockFace.swift

**137 lines.** What the clock shows, and when it changes: the pure `ClockFace` namespace (text for
each format and the tick schedule), the `ClockTicker` that fires on each change, and the
`FixedWidthDigits` view.

### `ClockFace`

A caseless `enum` used as a namespace of static functions. No state; callable from any thread,
though only used on the main actor.

#### `parts(_:format:seconds:)`

Returns a tuple `(main: String, small: String, caption: String?)`. `small` is a suffix drawn
smaller on the same baseline; `caption`, if present, replaces the date line.

**12-Hour and 24-Hour.** A `DateFormatter` with the `en_US_POSIX` locale and the pattern `HH:mm`
or `h:mm`, plus `:ss` with seconds. The POSIX locale fixes the pattern exactly, independent of
user preferences (which could otherwise force 24-hour display or change digits). For 12-hour the
formatter is re-used with pattern `" a"` to produce " AM"/" PM" (with the leading space) as the
small suffix. A new formatter is created on every call, i.e. on every tick.

**Swatch Internet Time.**

```swift
let s = (date.timeIntervalSince1970 + 3600).truncatingRemainder(dividingBy: 86400)
let beats = s / 86.4
let main = seconds ? String(format: "@%06.2f", beats) : String(format: "@%03d", Int(beats))
```
(`ClockFace.swift:22-24`)

Swatch's 1998 "Internet Time" divides the day into 1000 *.beats* and counts them from midnight in
Biel, Switzerland, at a fixed UTC+1 ("Biel Mean Time") with no daylight saving. So it is the same
number everywhere. The maths: Unix time counts seconds since 1970-01-01 00:00 UTC; adding 3600 s
shifts to UTC+1; the remainder modulo 86 400 is seconds since Biel midnight; one beat is
86 400 / 1000 = 86.4 s. Without seconds the display is `@` and three zero-padded digits (`@042`);
with seconds it shows hundredths of a beat (*centibeats*, 0.864 s each) as `@042.37`; `%06.2f`
pads the whole field to six characters so the integer part keeps three digits. Unix time ignores
leap seconds, which is what Internet Time does too. The caption is "Swatch Internet Time ·
.beats".

**French Decimal Time.**

```swift
let midnight = Calendar.current.startOfDay(for: date)
let ds = Int(date.timeIntervalSince(midnight) / 0.864)
let h = ds / 10000, m = (ds / 100) % 100, sec = ds % 100
```
(`ClockFace.swift:30-32`)

The French Republic's decree of 1793 divided the day into 10 hours of 100 minutes of 100 seconds:
100 000 decimal seconds per day, so one decimal second is 86 400 / 100 000 = 0.864 real seconds.
The code counts whole decimal seconds since local midnight, then splits the count: hours are the
ten-thousands, minutes the next two digits, seconds the last two. Noon is 5:00:00; 18:00 is
7:50:00. Output is `h:mm` or `h:mm:ss`. The caption is "Decimal Time · " plus the localised date.

**In Words.** Delegates to `words(_:)`; no caption.

#### `ticks(format:seconds:)`

Returns `(anchor, step)`: a moment when the display changed and the interval between changes.
`ClockTicker` fires at `anchor + k·step`.

| Format | Anchor | Step |
|---|---|---|
| 12/24-hour | Unix epoch | 1 s with seconds, else 60 s |
| Swatch | epoch − 3600 s (a Biel midnight) | 0.864 s (centibeat) or 86.4 s (beat) |
| Decimal | today's local midnight | 0.864 s or 86.4 s (decimal minute = 100 × 0.864) |
| Words | Unix epoch | 60 s |

The epoch works as an anchor for minutes because every UTC offset in use is a whole number of
minutes. For words the display changes only every 5 minutes, but ticking each minute is cheap and
avoids encoding the "nearest five" rounding rule here.

#### `words(_:)`

Converts the local time to English, rounded to the nearest five minutes.

1. Take hour and minute from `Calendar.current`.
2. `rounded = round(minute / 5) × 5`, in 0…60 (`Double.rounded()` rounds half away from zero, so
   :02:59 → 0 and :03 → 5; seconds are ignored because only hour and minute are extracted).
3. Above 30 the phrase is "… to" the next hour, so `hour += 1`; then `hour %= 24` (23:58 → 0).
4. `exact` is `rounded == 0 || rounded == 60`. Exact midnight → "midnight", exact noon →
   "noon", otherwise "<name> o'clock". Otherwise "<phrase> <name>", e.g. "twenty-five to six".
5. Names are indexed by `hour % 12` with index 0 = "twelve".

The force-unwrap `phrases[rounded]!` is safe because `rounded` is always a multiple of five in
0…60, all of which are keys.

### `ClockTicker`

**Responsibility.** Publish `now` exactly when the displayed time changes, never drifting.

**Threading / lifecycle.** `@MainActor ObservableObject`, owned by `DesktopClock` for the process
lifetime; `run` is called on each rebuild, `stop` when hidden. The timer's handler runs on the main
queue.

| Property | Type | Meaning |
|---|---|---|
| `now` | `@Published private(set) Date` | The time the view displays. |
| `timer` | `DispatchSourceTimer?` | The one pending timer. |
| `activity` | `NSObjectProtocol?` | Token from `ProcessInfo.beginActivity`, held while sub-minute ticks run. |
| `anchor` | `Date` | Reference boundary. |
| `step` | `TimeInterval` | Interval between boundaries. |

#### `run(anchor:step:)` and App Nap

macOS's *App Nap* throttles apps that are not visible to the user's attention: their timers can
be delayed by up to about a second and coalesced. An accessory helper whose only window is on the
desktop is a natural candidate. For a seconds display that would be visible as skipped seconds. So
when `step < 60` the ticker calls
`ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason:)`,
which tells the system the process is doing user-visible work and opts out of App Nap while still
allowing the Mac to sleep when idle. When the step becomes ≥ 60 it ends the activity. Then `now` is
set to the current date (an immediate redraw) and `scheduleNext()` is called.

#### `scheduleNext()`

```swift
let boundary = anchor.addingTimeInterval(((current.timeIntervalSince(anchor) / step).rounded(.down) + 1) * step)
let t = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
t.schedule(deadline: .now() + boundary.timeIntervalSince(current), leeway: .milliseconds(2))
t.setEventHandler { [weak self] in
    onMainActor {
        guard let self else { return }
        self.now = max(Date(), boundary) // woke a hair early: still show the new second
        self.scheduleNext()
    }
}
```
(`ClockFace.swift:106-115`)

- The next boundary is computed from the anchor, not by adding `step` to the previous fire time,
  so errors never accumulate: each tick is re-aimed at the true wall-clock boundary.
- A one-shot GCD timer with `.strict` flag and 2 ms leeway: `.strict` asks the kernel not to
  coalesce this timer with others beyond the stated leeway. (Ordinary `Timer`s on a run loop have
  no such guarantee and are subject to tolerance and App Nap.)
- `deadline: .now()` uses the monotonic dispatch clock; the interval is derived from wall-clock
  dates. If the wall clock jumps, the monotonic deadline does not move, which is why
  `DesktopClock` resyncs on `.NSSystemClockDidChange`.
- `max(Date(), boundary)`: if the timer fires a fraction of a millisecond early, the formatter
  would otherwise render the previous second. Clamping to the boundary guarantees the new value.
- The handler captures `self` weakly; the ticker owns the timer, so a strong capture would be a
  retain cycle.
- `timer?.cancel()` first, so only one timer exists at a time.

#### `stop()`

Cancels the timer and ends any activity. `now` keeps its last value.

### `FixedWidthDigits`

Proportional fonts give "1" less width than "0", so a seconds display makes the whole line shuffle
left and right. Most fonts offer tabular figures through a font feature, but the comment notes the
Aero fallback fonts lack them. This view measures each of the ten digits in the given `NSFont`,
takes the widest, and lays out the string one character per `Text` in an `HStack` with zero
spacing; digits get a frame of `ceil(widest)`, everything else (colon, `@`, `.`, spaces) its
natural width. `ForEach` uses the character offset as identity, which is stable because the
string's shape is fixed for a given format.

| Property | Type | Meaning |
|---|---|---|
| `text` | `String` | The string to draw. |
| `font` | `NSFont` | Font used for both measuring and drawing. |

### Notes and risks

- `ClockFace.swift:30-32` — decimal time divides seconds since *local* midnight by 0.864. On a
  daylight-saving day of 23 or 25 hours the count ends at 9:58:33 or passes 10:00:00 (ds up to
  104 166). The traditional definition assumes a 24-hour day.
- `ClockFace.swift:46` — the decimal anchor is today's midnight at the time of `refresh()`. After a
  DST change, local midnight shifts by 3600 s, which is not a multiple of 0.864 s, so ticks land
  between displayed changes until the next rebuild (e.g. wake).
- `ClockFace.swift:105-113` — if the timer fires slightly early, `scheduleNext()` recomputes the
  *same* boundary and schedules a near-zero timer, so the handler runs twice for one boundary.
  Harmless (the second publish shows the same text) but wasteful.
- `ClockFace.swift:11` — a `DateFormatter` is allocated per tick; `FixedWidthDigits` re-measures
  ten glyphs on every `body` evaluation (`:128`). Both are small costs at 1 Hz.
- `ClockFace.swift:85-91` — the App Nap activity is chosen by `step < 60`, so beats without
  centibeats (86.4 s) run without it; a delay of up to a second matters little at that step.

---

## Sources/Himawari/ClockHelper.swift

**66 lines.** The main app's side of the clock: start the helper process, restart it if it dies
(within limits), stop it on quit, and clean up the older launchd installation.

Called from `AppDelegate`: `clock.start()` in `applicationDidFinishLaunching`
(`AppDelegate.swift:40`) and `clock.stop()` in `applicationWillTerminate` (`:35-37`). Showing and
hiding the clock does **not** go through `ClockHelper`; that is a settings toggle
(`AppDelegate.toggleDesktopClock`, `:502-505`) that the running helper reacts to. The helper
process keeps running while the clock is hidden, so that it can show itself again instantly.

### `ClockHelper`

`@MainActor final class`, one instance owned by `AppDelegate` (`private let clock = ClockHelper()`).

| Property | Type | Meaning |
|---|---|---|
| `process` | `Process?` | The running helper, if any. |
| `stopping` | `Bool` | True when Himawari itself asked it to stop; suppresses restarts. |
| `restarts` | `[Date]` | Times of recent automatic restarts (sliding one-minute window). |
| `executable` (computed) | `URL?` | `Contents/Helpers/Desktop Clock.app/Contents/MacOS/HimawariClock` inside the running bundle, if it exists and is executable. |

**Background: `Process`.** Foundation's `Process` (formerly `NSTask`) launches a child process
directly with `posix_spawn`. It is not launched through Launch Services, so the helper app does not
appear as "opened" and macOS does not track it as a separate login item; it is simply Himawari's
child. By default the child inherits the parent's standard input, output and error, which is why
the clock's `print` lines land in Himawari's output. `terminationHandler` is called on a
background thread when the child exits.

#### `start()`

1. `retireOldService()` (once-only cleanup, below).
2. If a process is already running, or the executable is missing (a build without the helper,
   e.g. running the bare binary from `.build`), return; log the missing case.
3. Clear `stopping`; build a `Process` with arguments `["--parent", <own pid>]` (consumed by the
   watchdog in `main.swift`).
4. Install a termination handler that hops to the main queue and calls `ended()`, capturing `self`
   weakly.
5. `try p.run()`; on success store it, on failure log.

#### `stop()`

Sets `stopping`, sends `SIGTERM` with `process?.terminate()`, and clears `process`. The helper's
`runBackgroundService` catches SIGTERM through a dispatch signal source and calls `exit(0)`. If
Himawari is quitting, the helper may outlive it for a moment; the watchdog covers anything left.

#### `ended()` — restart policy

```swift
process = nil
guard !stopping else { return }
// Start it again, but not in a loop: at most 3 times a minute.
restarts = restarts.filter { Date().timeIntervalSince($0) < 60 } + [Date()]
guard restarts.count <= 3 else { Log.write("clock: keeps stopping; leaving it off"); return }
DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in onMainActor { self?.start() } }
```
(`ClockHelper.swift:42-47`)

An unexpected exit is restarted after 1 s. The array keeps only exits from the last 60 s plus this
one; if more than three fall in that window, the helper is left off (until Himawari is relaunched)
rather than crash-looping and burning CPU. The 1 s delay also prevents a tight loop when the crash
is immediate.

#### `retireOldService()` — launchd migration

Before the clock moved into the app bundle it was a per-user **launchd agent**: a property list in
`~/Library/LaunchAgents/` that launchd loads at login and keeps running. `launchctl bootout
gui/<uid>/<label>` is the modern command to unload a job from the user's GUI *domain* (the
per-login-session launchd namespace) and stop it. The function:

1. Checks for `~/Library/LaunchAgents/local.dhairyabhatia.desktop.clock.plist`; if absent, returns
   (so after the first run this is a single `fileExists` call).
2. Runs `/bin/launchctl bootout gui/<uid>/local.dhairyabhatia.desktop.clock` and waits for it.
3. Deletes the plist and the old copy of the clock app at
   `~/Library/Application Support/Desktop Shell/Desktop Clock.app`.
4. Logs the migration.

Without this, both the old agent and the new helper would draw a clock. Only those two paths are
removed; the rest of the old project's folder is left alone.

### Notes and risks

- `ClockHelper.swift:61` — `waitUntilExit()` runs on the main thread during launch; `launchctl` is
  quick, but the call blocks the UI until it returns.
- `ClockHelper.swift:35-48` — if `start()` were called after `stop()` but before the old process
  exited, the old process's `ended()` would see `stopping == false`, set `process = nil` (dropping
  the *new* process) and schedule another start, giving two clocks. Today `stop()` is only called
  at quit, so this does not happen in practice.
- `ClockHelper.swift:46` — after three crashes in a minute the clock stays off for the rest of the
  session; nothing in the UI says so beyond the log, and the menu's "Show Desktop Clock" toggle
  then has no visible effect.
- `ClockHelper.swift:28` — the helper inherits Himawari's stdout/stderr; no pipe is set up.

---

## Sources/HimawariKit/WallpaperTone.swift

**194 lines.** Shared by both processes (it is in `HimawariKit`). It defines how brightness is
measured (`FrameSampler`, the 8×8 grid), how a reading of the clock's spot is computed, and the
distributed-notification protocol between the clock and Himawari.

### Design: no screen capture

The obvious way to know what is behind the clock would be to capture the screen. That needs the
Screen Recording permission (a TCC prompt), costs GPU time, and would include the clock itself.
Instead, the process that *draws* the wallpaper describes it: Himawari already has the video's
frames, the album art, or a YouTube thumbnail, and knows where each is drawn. It turns that into a
brightness function over the screen and samples it. Without Himawari, the clock measures the
macOS wallpaper image file. The header comment says this explicitly: "No screen recording is
involved."

Coordinates in this file are mostly **screen fractions with y running down**: `(u, v)` in 0…1,
`(0, 0)` at the top-left of the main screen. AppKit uses points with y running up, so conversions
flip y (`f.maxY − rect.maxY`).

### `WallpaperTone` (namespace)

`public enum WallpaperTone` with `size = 8` (the grid is 8×8, stored row-major, row 0 at the top).

#### `brightness(of:under:on:)`

Averages the grid cells overlapped by an AppKit rectangle. It maps the rectangle's edges to cell
indices (rounding the lower edges down and the upper edges up, so any partially covered cell
counts), flips y because grid rows run top to bottom, clamps to the grid, and guarantees at least
one cell with `max(y1, y0 + 1)`. The private `Int.clamped(_:_:)` extension (`:50-52`) does the
clamping. Used by the clock when no `focus` is available.

#### `grid(of:screenAspect:)`

Builds a grid for an image displayed as the macOS wallpaper does by default, i.e. *aspect fill*
(scaled to cover the screen and cropped). For each screen position it computes the image position:
if the image is wider than the screen, it squeezes `u` toward the centre by
`screenAspect / imageAspect` (cropping the sides); otherwise it squeezes `v` (cropping top and
bottom). It reuses `reading(of:region:)` with no region and returns only the grid.

#### `systemWallpaperGrid(for:)`

`@MainActor`. Asks `NSWorkspace.shared.desktopImageURL(for:)` for the screen's wallpaper file,
loads it with `NSImage`, gets a `CGImage`, and measures it with the screen's aspect ratio. Returns
`nil` if any step fails. For wallpaper choices that are not a single image file (Aerials, dynamic
wallpapers) the URL may point at a placeholder or a multi-image HEIC, of which `NSImage` uses the
first representation; the result is then approximate.

#### The protocol: `ToneReading`, `post`, `observeReadings`, `requestReading`, `onReadingRequest`

**Background: distributed notifications.** `DistributedNotificationCenter` is a system-wide
notification bus (backed by the `distnoted` daemon) through which any process in the same login
session can post a named notification and any process can observe it. The `userInfo` dictionary
must contain only property-list types (here `NSNumber` and arrays of them). Posting with
`deliverImmediately: true` asks for delivery even to observers whose apps are suspended or
hidden, instead of queuing until they become active. It is a broadcast: there is no addressing,
no reply, and no authentication of the sender.

`ToneReading` is a `Sendable` struct:

| Property | Type | Meaning |
|---|---|---|
| `grid` | `[Double]` | 64 brightness values, 0 = black, 1 = white, rows top → bottom. |
| `focus` | `Double?` | Mean brightness exactly behind the clock, when Himawari knows the clock's region. |
| `spread` | `Double?` | Standard deviation of brightness there (0…0.5): how busy the picture is. |

Two notification names:

| Name | Direction | userInfo |
|---|---|---|
| `local.dhairyabhatia.wallpaperTone.request` | clock → Himawari | `region: [x, y, w, h]` (fractions, y down) |
| `local.dhairyabhatia.wallpaperTone.reading` | Himawari → clock | `grid: [64 × NSNumber]`, optional `focus`, `spread` |

`post(_:)` encodes and posts a reading. `observeReadings(_:)` decodes it on the main queue,
**validates** that the grid has exactly 64 values (a malformed or foreign post is dropped), and
calls the block. `requestReading(for:)` posts the region; `onReadingRequest(_:)` decodes it,
requiring four numbers. Both observer registrations are `@MainActor` and use `queue: .main`, then
enter main-actor code through `onMainActor`. The observer tokens are discarded, which is fine for
registrations meant to last the whole process.

The exchange:

```
clock                                  Himawari
  │ refresh(): window placed             │
  │── request(region) ─────────────────▶ │ ToneReporter.clockMoved: store region,
  │                                      │   publish(force: true)
  │ ◀──────────────── reading(grid,focus,spread)
  │ updateTone()                         │
  │                                      │ new frame/scene/thumbnail → show(...)
  │ ◀──── reading (only if it changed noticeably)
  │                                      │
  │      (Himawari restarts: posts a reading with focus == nil)
  │ ◀──── reading(grid)                  │
  │── request(region) ─────────────────▶ │  (clock re-announces itself)
```

#### `fraction(of:on:)`

Converts an AppKit rectangle to screen fractions with y down: x relative to `frame.minX`, y as
`(frame.maxY − rect.maxY) / height`.

#### `reading(of:region:)` — the sampler

```swift
for cy in 0..<size {
    for cx in 0..<size {
        var sum = 0.0
        for sy in 0..<3 { for sx in 0..<3 {
            sum += luma((Double(cx) + (Double(sx) + 0.5) / 3) / Double(size),
                        (Double(cy) + (Double(sy) + 0.5) / 3) / Double(size))
        } }
        grid[cy * size + cx] = sum / 9
    }
}
```
(`WallpaperTone.swift:122-131`)

Given a brightness function `luma(u, v)`, each of the 64 cells is the mean of a 3×3 sub-grid of
samples at the centres of nine equal sub-cells (576 samples). If a region is given, 200 more
samples (20 across × 10 down, matching a wide clock) are taken at sub-cell centres inside it, and
their mean becomes `focus` and their population standard deviation `spread`. For values in 0…1 the
standard deviation is at most 0.5 (half black, half white), which is the range the clock's 0.13 /
0.19 thresholds are tuned for.

### `FrameSampler`

A small immutable copy of a picture in BGRA bytes, used throughout Himawari (ambient bar colours,
disc art, tone). It is a `Sendable` struct, so it can be built on one thread and read on another.

| Property | Type | Meaning |
|---|---|---|
| `pixels` | `[UInt8]` (private) | BGRA bytes, row 0 = top of the picture. |
| `width`, `height` | `Int` | Dimensions in pixels. |
| `row` | `Int` (private) | Bytes per row (may exceed `width × 4` for pixel buffers, because of alignment padding). |

- **`init?(_ buffer: CVPixelBuffer)`**: locks the buffer's base address read-only (Core Video
  requires the lock before CPU access to possibly GPU-backed memory), copies `row × height` bytes,
  unlocks via `defer`. Fails on a nil base address or empty size. It assumes a packed 32-bit BGRA
  buffer; callers request `kCVPixelFormatType_32BGRA` at 64×64 from `AVPlayerItemVideoOutput`
  (`WallpaperManager.swift:227-229`), so the copy is 16 KB.
- **`init?(_ image: CGImage, side: Int = 64)`**: draws the image into a `side×side` sRGB bitmap
  context with `premultipliedFirst | byteOrder32Little`, which on a little-endian Mac is BGRA in
  memory. The image is stretched to a square; that is fine because all sampling uses normalised
  coordinates. Core Graphics' origin is bottom-left, but in a bitmap context memory row 0 is the top
  of the drawn image, as the comment says.
- **`rgb(_:_:)`**: nearest-pixel lookup at `(u, v)`, clamped to the edges, returning
  `SIMD3(r, g, b)` in 0…1 (reading bytes `i+2, i+1, i` for BGRA).
- **`luma(_:_:)`** and **`static luma(_:)`**: `0.2126 R + 0.7152 G + 0.0722 B`, the Rec. 709
  luma weights (green dominates perceived brightness). They are applied to gamma-encoded values,
  which is standard for "luma" (Y′) as opposed to linear luminance.
- **`average(_:)`**: mean colour over a rectangle from an 8×8 grid of samples.

### Notes and risks

- `WallpaperTone.swift:79,97` — any local process can post these notification names; a spoofed
  reading could only change the clock's colours. There is no sender check (distributed
  notifications cannot provide one).
- `WallpaperTone.swift:150-157` — the pixel-buffer initialiser does not check the pixel format; a
  planar (YUV) buffer would be misread. All current callers request BGRA.
- `WallpaperTone.swift:165,178` — with premultiplied alpha, transparent areas of an image read as
  dark; covers with transparency would bias readings toward "dark background".
- `WallpaperTone.swift:43-47` — `systemWallpaperGrid` loads the full-resolution wallpaper (often a
  6K HEIC) on the main actor at clock startup.

---

## Sources/Himawari/ToneReporter.swift

**73 lines.** Himawari's side of the protocol: it keeps a brightness function for "what is on
screen now", samples it for the clock's region, and posts readings when they change.

It is owned by `WallpaperManager` (`private let tone = ToneReporter()`, `WallpaperManager.swift:22`),
which feeds it from three sources:

| Source | Call | Where |
|---|---|---|
| The video (sampled periodically) | `show(frame, visible:, full:, fill:, force: false)` | `WallpaperManager.sampleTone`, `:252` |
| The CD scene (album art on a disc) | `show(frame, visible: disc, full: disc, fill: palette.luma, force: true)` | `sceneTone`, `:372` |
| A YouTube video | `showYouTube(id:on:filling:stillCurrent:)` | `youTubeTone`, `:272` |
| Clock region request | `clockMoved(to:)` | via `AppDelegate.swift:143` → `WallpaperManager.clockMoved` |
| Content gone | `clear()` | `:305`, `:483` |

### `ToneReporter`

`@MainActor final class`.

| Property | Type | Meaning |
|---|---|---|
| `clockRegion` | `CGRect?` | Where the clock is (screen fractions, y down), from its last request. |
| `screenLuma` | `((Double, Double) -> Double)?` | Brightness of the screen at `(u, v)`; `nil` = nothing to report. |
| `lastReading` | `ToneReading?` | Last posted reading, for change detection. |

#### `clockMoved(to:)`

Stores the region and publishes with `force: true`, so a clock that has just moved or started gets
an answer immediately even if nothing on screen changed.

#### `show(_:visible:full:fill:force:)`

Builds the brightness function:

```swift
screenLuma = { u, v in
    guard full.width > 0, full.height > 0, visible.contains(CGPoint(x: u, y: v)) else { return fill }
    return frame.luma((u - full.minX) / full.width, (v - full.minY) / full.height)
}
```
(`ToneReporter.swift:25-28`)

`full` is the rectangle where the whole frame would be drawn (it may extend past the screen when the
video is scaled to fill); `visible` is the part actually seen. Inside `visible` the function maps
screen coordinates into frame coordinates; outside it returns `fill`, the brightness of the bars
around the video (0 for black bars, the ambient palette's luma, or 55 % of the frame's mean for
blurred bars, as computed in `WallpaperManager.swift:243-251`). The closure captures the
`FrameSampler` by value, so the reporter holds a 64×64 copy and no reference to the player.

#### `clear()`

Sets `screenLuma = nil`; `publish` then does nothing until the next `show`. Used when the CD scene
leaves or the video changes, so a stale reading of the old content is not re-sent.

#### `showYouTube(id:on:filling:stillCurrent:)`

A YouTube player in a web view cannot be read pixel-by-pixel (a cross-origin video in WebKit is not
accessible to the host), so the reporter measures the video's thumbnail instead:
`https://i.ytimg.com/vi/<id>/mqdefault.jpg` (320×180).

It reproduces the geometry the player uses:

- **Filling** (`sizing == .fill`): the 16:9 video covers the screen. If the screen is wider than
  16:9, `full` is full width and taller than the screen, centred vertically; otherwise full height
  and wider than the screen, centred horizontally.
- **Not filling**: the video spans the full width with height `width × 9/16`, centred in the area
  below the menu-bar strip (`screen.menuBarStripHeight`, which accounts for a notch).

`visible` is `full` intersected with the screen (minus the menu-bar strip when not filling). The
download runs in a `Task`, which inherits the main actor from the enclosing method, so the
continuation runs on the main actor. When the data arrives it decodes the image, builds a
`FrameSampler`, and checks `stillCurrent()` (a closure that compares the current YouTube id) so a
late thumbnail for a video that has since changed is discarded. It then calls `show` with
`fill: 0` (the player's letterbox is black) and `force: true`.

#### `publish(force:)` and `differ(_:_:)`

`publish` samples the function with `WallpaperTone.reading(of:region:)` (776 samples), and unless
forced, posts only if `differ` says the change is noticeable: any grid cell moved by more than
0.06, or `focus` or `spread` by more than 0.04. `nil` values are compared as −1, so a reading
gaining or losing a `focus` always counts as a change. The thresholds limit cross-process traffic
to real changes; the clock's own hysteresis then decides whether the change matters for the text.

### Notes and risks

- `ToneReporter.swift:52-57` — the thumbnail download has no timeout beyond `URLSession`'s default
  and no cache; if it fails (offline), nothing is reported and the clock keeps its previous
  reading, which may describe the previous wallpaper.
- `ToneReporter.swift:38` — `mqdefault` is a 16:9 crop; for vertical or 4:3 videos it may not
  match what the player shows.
- `ToneReporter.swift:12,62` — before the clock has sent its region, readings carry no `focus`;
  `DesktopClock.init` treats a `nil` focus as "Himawari doesn't know where I am" and sends a request,
  which is the intended handshake but means every pre-request reading triggers one.

---

## Sources/HimawariKit/Hotkeys.swift

**218 lines.** System-wide keyboard shortcuts through Carbon, plus three helpers (`Ghostty`,
`FullScreen`, `Keys`) that no code in this repository calls. They come from the "Desktop Shell"
project the code was split from (the `⌘⌃T` terminal shortcut and the "Allow Desktop Hotkeys…"
message refer to it).

### `HotKey`

**Background: Carbon hot keys.** Carbon is the C API layer from the Mac OS 9 → X transition. Its
Event Manager function `RegisterEventHotKey` is still the standard way for an app to own a global
shortcut: the window server watches for the key combination and sends a `kEventHotKeyPressed`
Carbon event to the registering app, whichever app is frontmost. It needs no Accessibility or
Input Monitoring permission (unlike a `CGEventTap` or `NSEvent.addGlobalMonitorForEvents`, which
watch all keystrokes). Registration fails if another app already holds the same combination.

`@MainActor public final class HotKey`.

| Property | Type | Meaning |
|---|---|---|
| `ref` | `EventHotKeyRef?` | Carbon handle for unregistering. |
| `id` | `UInt32` | Caller-chosen number identifying this shortcut. |
| `actions` (static) | `[UInt32: () -> Void]` | id → action, shared by all instances. |
| `handlerInstalled` (static) | `Bool` | Whether the single Carbon event handler is installed. |

- **`init?(keyCode:modifiers:id:action:)`**: stores the action under `id`, installs the handler
  once, and calls `RegisterEventHotKey` with an `EventHotKeyID` whose signature is `'HNBI'`
  (`0x484E4249`, a four-character code identifying the app) and the given id, targeting the
  application event target. If the status is not `noErr`, it removes the action and fails (returns
  `nil`). `keyCode` is a virtual key code (`kVK_ANSI_C`), `modifiers` Carbon masks (`cmdKey |
  optionKey | controlKey`).
- **`unregister()`**: `UnregisterEventHotKey` and removes the action.
- **`installHandler()`**: installs one `InstallEventHandler` callback for
  `kEventClassKeyboard`/`kEventHotKeyPressed`. The callback is a C function pointer, so it cannot
  capture context; it reads the `EventHotKeyID` from the event with `GetEventParameter`, takes the
  id, and dispatches `HotKey.actions[id]?()` asynchronously to the main queue. Static storage is how
  the context-free callback finds the action. It returns `noErr` (event handled).

**Use in Himawari** (`AppDelegate.swift:67-75`): id 7, ⌃⌥⌘C toggles the desktop clock (the way back
after "Hide Clock"); id 8, ⌃⌥⌘D hides or shows desktop files. A `nil` result is logged ("taken by
another app"). The menu items show the same combinations as key equivalents for discoverability.

### `Ghostty` (unused here)

Opens a new window of the Ghostty terminal on the current Space. `newWindow()` checks
`currentSpaceIsFullScreen()`: over a full-screen app it calls `quickTerminalHere()`, otherwise it
runs `open -na <Ghostty.app> --args --quit-after-last-window-closed=true` — a *new instance*
(`-n`), because activating the existing instance would make macOS switch to a Space where it
already has windows. `quickTerminalHere()` presses Ghostty's "Quick Terminal" menu item through the
Accessibility API on the oldest running instance; if none is running it starts one with
`--initial-window=false` and presses the item after 1.5 s; without Accessibility permission it shows
a notification via `osascript` and opens the Privacy ▸ Accessibility pane once
(`askedForAccessibility`). `pressMenuItem(_:in:)` walks the app's `AXMenuBar` → menu bar items →
menus → items looking for a matching `AXTitle` and performs `AXPress`, which does not activate the
app. `attribute` and `element` are typed wrappers over `AXUIElementCopyAttributeValue` (the latter
checks the CF type ID before the forced cast). `run` launches a tool with `Process` without
waiting. `appPath` resolves the app via Launch Services by bundle id. `log` prints and flushes.
`currentSpaceIsFullScreen()` returns false when Ghostty itself is frontmost and otherwise delegates
to `FullScreen`.

### `FullScreen` (unused here)

`frontAppIsFullScreen()` reads `CGWindowListCopyWindowInfo([.optionOnScreenOnly,
.excludeDesktopElements], kCGNullWindowID)` — window bounds need no permission, only titles do —
and looks for a layer-0 window of the frontmost app that spans the main screen's full width
(±2 pt), starts at the top or just below the notch/menu bar, and reaches the bottom edge. The
screen frame is converted to the top-left-origin coordinates CGWindowList uses via the first
screen's height. The comment explains the test: on a notched MacBook a full-screen window stops
below the menu-bar strip, while normal windows never reach the bottom because of the Dock area.

### `Keys` (unused here)

`press(_:flags:to:)` synthesises a key down and key up with `CGEvent` from an HID-state source,
posting either to a specific pid or to the HID event tap (requires Accessibility). `spotlight()`
presses ⌘Space after 0.15 s if the process is trusted.

### Notes and risks

- `Hotkeys.swift:9-47` — `HotKey` has no `deinit`; releasing an instance without `unregister()`
  leaves the shortcut registered and the action in the static table. Himawari keeps both instances
  for its lifetime, so it is not triggered today.
- `Hotkeys.swift:22-24` — a failed registration clears `actions[id]`, which would also remove an
  existing action registered earlier under the same id.
- `Hotkeys.swift:49-218` — `Ghostty`, `FullScreen` and `Keys` have no callers in this repository
  (dead code from Desktop Shell). They are public in `HimawariKit` and compiled into both
  executables.

---

## Sources/HimawariKit/AeroStyle.swift

**76 lines.** The shared "Frutiger Aero" look: a humanist font, aqua glow colours and glossy glass
shapes. In this repository only `aeroFont`, `aeroNSFont` and `Color.aeroGlow` are used, by the
clock (`DesktopClock.swift:148,150,211,273`).

- **`Color.aeroGlow`** `(0.35, 0.80, 1.0)` and **`Color.aeroBlue`** `(0.25, 0.65, 1.0)`: the two
  aqua tones.
- **`aeroNSFont(size:weight:)`** tries, in order, the families Frutiger, Frutiger LT Std, Segoe UI,
  Myriad Pro and Avenir Next through `NSFontManager.font(withFamily:traits:weight:size:)`, and falls
  back to the system font. `NSFontManager` uses a 0–15 weight scale where 5 is regular and 9 bold;
  the function maps `.light` → 4, `.semibold` → 8, anything else → 5, and the font manager returns
  the closest available weight. Frutiger and Segoe UI are not shipped with macOS (they are used if
  installed); Avenir Next is, so on a stock Mac the clock's Aero style renders in Avenir Next.
- **`aeroFont(size:weight:)`** wraps it as a SwiftUI `Font`.
- **`View.aeroText(opacity:glow:)`**: white text, aqua glow r=8 and a faint black drop shadow.
- **`AeroGlass`**: a rounded rectangle (continuous corners, default radius 22) with three layers —
  an aqua-to-blue tint, a white gloss that stops sharply at the vertical midpoint (the gradient
  stops at 0.48 and 0.5 create the hard edge typical of the Aero look), and a gradient rim stroke.
- **`AeroBar`**: a capsule progress bar (8 pt tall) that fills `value` clamped to 0…1 of the width
  given by a `GeometryReader`, with a minimum fill width of 8 so the capsule stays round, a top
  gloss and an aqua glow.

No state beyond the stored properties shown (`cornerRadius`, `value`); all are value types used on
the main thread by SwiftUI.

### Notes and risks

- `AeroStyle.swift:19` — weights other than light and semibold map to regular, so for example
  `.bold` requests from callers would silently render regular in the Aero fonts.
- `AeroStyle.swift:28-76` — `aeroText`, `AeroGlass`, `AeroBar` and `Color.aeroBlue` (outside
  these views) have no callers in this repository.
