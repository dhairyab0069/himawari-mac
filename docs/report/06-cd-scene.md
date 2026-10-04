# 6 · The CD scene

When a song plays in Apple Music and there is nothing to loop behind it (no motion artwork, and no
YouTube video, or YouTube is turned off), Himawari puts the album cover on the wallpaper as a
compact disc. The disc spins slowly over a soft glow in the cover's colours. It slides out and a new
one slides in when the song changes, and you can grab it and turn it like a record to scrub. Small
animals and two chibi characters run along the bottom of the screen. The scene is two files:

| File | Lines | Role |
|---|---|---|
| `Sources/Himawari/MusicScene.swift` | 656 | The `NSView` holding the whole scene, the `Sprites` cache of characters, and the `DiscDirection` enum |
| `Sources/Himawari/DiscPrint.swift` | 106 | A pure function that turns a square cover into a disc-shaped "print" with pressed tracks, placed so the hub avoids the busy parts of the art |

Almost everything in the scene is Core Animation. Once the layers and their animations are set up,
the window server (the `WindowServer` process, through its render server) draws every frame. The app
process does no per-frame work. That is the main design decision in this chapter, and it explains
most of the code's shape. Nothing redraws in `draw(_:)`, no timers tick, and there is no display
link. The code builds a tree of layers once per size, attaches long-running animations to it, and
replaces parts of the tree when something changes.

---

## Core Animation primer for this chapter

The rest of the chapter assumes these ideas. Readers who know Core Animation can skip ahead.

- **`CALayer`** is a rectangle that Core Animation composites. It has `bounds` (its own coordinate
  space), a `position` (where its `anchorPoint`, by default the centre, sits in the superlayer),
  a `transform` (a `CATransform3D` applied around the anchor point), `contents` (usually a
  `CGImage`), `opacity`, a shadow, an optional `mask` layer, and sublayers. On macOS a layer-backed
  `NSView` (with `wantsLayer = true`) uses a coordinate space with the origin at the bottom left and
  y pointing up, unless the view is flipped. `MusicScene` is not flipped, so every rectangle in it
  is y-up.
- **Model and presentation trees.** Setting a property such as `layer.transform` changes the
  *model* value. An animation changes only what is drawn, which `layer.presentation()` reports.
  When an animation is removed, the layer jumps back to its model value. That is why `grabDisc`
  reads the presentation rotation and writes it into the model before it removes the spin.
- **Implicit actions.** Changing an animatable property of a standalone layer (one that does not
  back a view) normally animates it over 0.25 s. `CATransaction.setDisableActions(true)` inside a
  `begin()`/`commit()` pair turns that off, so changes take effect at once. The scene wraps every
  structural change this way.
- **`CABasicAnimation`** interpolates one key path (`"position.x"`, `"opacity"`,
  `"transform.rotation.z"`, `"transform.scale"`, `"transform.translation.y"`) from `fromValue` to
  `toValue`, or by `byValue`. A missing `fromValue` means "from the current presentation value".
  **`CAKeyframeAnimation`** goes through a list of `values` at given `keyTimes` (fractions of the
  duration), with optional per-segment `timingFunctions` or `calculationMode = .cubic` for smooth
  curves. **`CAAnimationGroup`** runs several animations under one duration, one timing function
  and one `beginTime`.
- **Timing.** `CAMediaTimingFunction(controlPoints:)` is a cubic Bézier easing curve from (0,0) to
  (1,1). `fillMode = .forwards` with `isRemovedOnCompletion = false` keeps the final value on
  screen after the animation ends. `.backwards` shows the first value before a delayed `beginTime`
  arrives. `isAdditive = true` adds the animated value on top of whatever the other animations and
  the model produce, which lets an extra spin stack on the regular spin.
- **Layer time.** Each layer has its own time, derived from its parent's through `beginTime`,
  `speed` and `timeOffset`. Setting a layer's `speed` to 0 freezes every animation beneath it.
  `layer.convertTime(CACurrentMediaTime(), from: nil)` turns host time into that layer's local
  time. The scene's pause and resume (`updateClock`) is built on this.
- **`preferredFrameRateRange`** (`CAFrameRateRange`, macOS 14+) tells the render server how often
  an animation needs new frames. The scene asks for 15–30 fps for the spin, 10–20 fps for the slow
  luster sway, 20–30 fps for the runners, and 30–60 fps only for the one-second disc slides. On
  ProMotion displays, a low rate lets the display and GPU slow down.
- **`CAShapeLayer`** draws a `CGPath`. Used as a `mask`, its filled area decides where the masked
  layer shows. **`CAGradientLayer`** draws axial, radial (`.radial`) or conic (`.conic`, an angular
  sweep around `startPoint`) gradients. The scene uses conic gradients for the silver ring and the
  rainbow luster, and a radial gradient as a soft mask.
- **`contentsScale`** says how many pixels back each point of a layer's contents. It matters for
  content the layer draws itself. For a `CGImage` assigned to `contents` and stretched with
  `contentsGravity = .resize`, the image's pixel count matters more.

---

## Sources/Himawari/MusicScene.swift

### What the file is for and where it sits

`MusicScene.swift` (656 lines, imports AppKit, HimawariKit and QuartzCore) holds three types:

1. `MusicScene`, a `@MainActor final class` subclassing `NSView`, which is the scene.
2. `Sprites`, a `@MainActor enum` namespace that draws and caches the runners' pictures.
3. `DiscDirection`, a two-case enum saying which way discs travel on a song change.

The owner is `WallpaperManager` (chapter on the wallpaper). It keeps `scenes: [MusicScene]`, one
per wallpaper window, so one per screen. The flow in and out:

```
AppDelegate.updateWallpaper…  ──► WallpaperManager.setScene(art)            (WallpaperManager.swift:278)
        │                              │
        │ noteDirection() sets         ├─ first cover:  addScene(to:) per window
        │ wallpaper.discDirection      │        MusicScene(frame:artwork:topInset:bottomInset:)
        │ (AppDelegate.swift:268/272)  │        .running = desktopVisible, .lively = !PowerState.saving
        │                              │        .arrive(from: discDirection)
        │                              ├─ new song:     scene.setArtwork(art, direction:)
        │                              ├─ same song, sharper art: scene.repaint(with:)
        │                              └─ no art:       scene.leave { removeFromSuperview() }
        │
WallpaperManager.setDesktopVisible / setPlaying ──► scene.running
WallpaperManager.powerChanged                   ──► scene.lively
WallpaperManager.applySong                      ──► scene.setSong / meterSource / levelsChanged
WallpaperManager.sceneTone                      ──► reads scene.discRect, scene.palette  → ToneReporter
GearControls.update / discCatcher               ──► reads scene.discRect, calls grab/turn/releaseDisc, scene.gear
```

`MusicScene` in turn calls `DiscPrint.make` (on a global queue), `FrameSampler` and
`AmbientPalette.from` (HimawariKit and `AmbientFill.swift`) to get the glow colours, `AmbientLayer`
for the glow, `NowPlayingSides` for the "side gear" (the hi-fi panels with VU meters, jog wheel
and song info beside the disc), and `Sprites` for the runners.

### Design decisions

- **Core Animation, not a render loop.** A wallpaper is on screen all day. With the animations
  handed to the render server and low frame-rate ranges requested, the app's CPU cost while the
  disc spins is close to zero. The alternatives were a `CVDisplayLink`/`CADisplayLink` redrawing a
  bitmap, or Metal. Both would wake the app every frame.
- **Only the print spins.** The silver ring, the hole edges and the shadow look the same at every
  angle, so they sit still. Only the `disc` layer (the cover print) carries the rotation. The
  luster (the rainbow sheen) is deliberately *not* on the disc. It "belongs to the light", so it
  sits above the disc in `discStage` and stays still (or sways slightly) while the print turns
  beneath it. That is how a real CD's reflection behaves.
- **Swap, don't mutate.** A song change builds a whole new holder+disc pair, slides it in and
  throws the old pair away. Two discs exist on screen at once during the change. Animating one
  disc out and back in would mean the old cover could not still be visible leaving while the new
  one arrives.
- **The print is precomputed.** Wrapping the art (cutting it to a ring, adding track texture,
  choosing placement) is done once per cover and size on a background queue, so the render server
  only stretches a ready bitmap.
- **One clock to pause everything.** All animated layers hang under `stage` or `discStage`.
  Pausing sets those two layers' `speed` to 0, which freezes everything beneath them where it is.

### The layer tree

```
MusicScene (NSView, layer-backed, black background)
└─ layer (the view's backing layer)
   ├─ stage                     CALayer   ← clock 1 (paused/resumed by updateClock)
   │  ├─ ambient                AmbientLayer: four drifting colour blobs (the glow)
   │  └─ runners                CALayer: one sublayer per runner
   │      └─ runner → hopper → sprite   (crosses / hops+waddles / mirrored picture)
   ├─ sides's layer             NowPlayingSides (an NSView subview: panels, meters, jog wheel)
   └─ discStage  zPosition 10   CALayer   ← clock 2
      ├─ holder  (old, during a change; removed after 1.5 s)
      ├─ holder                 CALayer: shadow, position = disc centre; slides on changes
      │  ├─ mirror              CAGradientLayer .conic, masked to the silver ring
      │  ├─ edges               CAShapeLayer: two 1-pt circles (hole edge, print edge)
      │  └─ disc                CALayer: contents = print, masked to the outer ring, SPINS
      └─ sheen                  CAGradientLayer .conic rainbow, radial-gradient mask, sways
```

`discStage` is added to the view's layer *after* `sides` is added as a subview, and it gets
`zPosition = 10`. The comment at `MusicScene.swift:96` explains why: when discs change they travel
across the whole width of the screen, crossing the side panels, and they should pass *over* them.
At rest the disc sits between the panels, so the z-order hides nothing.

### The disc's geometry

All radii are fractions of the disc radius `r = side / 2`, in the private enum `CD`
(`MusicScene.swift:309`):

| Constant | Value | Meaning |
|---|---|---|
| `CD.hole` | 0.09 | radius of the see-through centre hole |
| `CD.print` | 0.22 | the silver ring runs from the hole out to here; the printed picture starts here |
| `CD.luster` | 0.43 | the rainbow sheen has faded to nothing by this radius |

A real 120 mm CD has a 15 mm hole (0.125 of the radius) and a clear/mirror hub out to roughly
0.38. The scene's proportions are smaller than real ones, which gives the cover more area.

```
                 ┌────────────── r (1.00) outer rim: print + shadow end here
                 │      ┌─────── 0.43 luster gone
                 │      │   ┌─── 0.28 (0.43 × 0.65) luster at full strength out to here
                 │      │   │  ┌ 0.22 print edge (1-pt white line, alpha 0.32)
                 │      │   │  │ ┌ 0.10 luster starts (hole + 0.01)
                 │      │   │  │ │┌ 0.09 hole edge (1-pt line); nothing drawn inside
                 ▼      ▼   ▼  ▼ ▼▼
   . . . . . . . .:::::::::::::::::::::::::::::::::. . . . . . .
   rim |  print (cover art, tracks) | silver |hole| silver |  print  | rim
       |<----- disc layer, masked to ring 0.22…1.00 ---->|
                              |<mirror>|    |<mirror>|  ring 0.09…0.22
                         |<-- sheen, radial mask: 0.10→0.28 full, →0.43 fade -->|

  Seen from the front:

               .-~~~~~~~~~~~-.
            .~   print (art)   ~.
          /     .-~~~~~~~~-.      \
         |    /   silver    \      |       ← sheen streaks at 35° and 215°,
         |   |    .----.     |     |         over the inner part of the print
         |   |   ( hole )    |     |         and the silver ring
         |   |    '----'     |     |
         |    \             /      |
          \    '-~~~~~~~~-'       /
            '~                 ~'
               '-~~~~~~~~~~~-'
```

### `MusicScene`: responsibility, state, lifecycle, threading

**Responsibility.** Show one cover as a spinning CD in the middle of one screen, change discs with
a direction-aware slide, let the user turn it by hand, freeze when invisible, simplify in Battery
Saver, and report where the disc is and what colours the scene glows with.

**Threading.** The class is `@MainActor`. Every method runs on the main thread. The only off-main
work is `DiscPrint.make`, dispatched from `renderPrint` onto
`DispatchQueue.global(qos: .userInitiated)` and handed back with `DispatchQueue.main.async` plus
HimawariKit's `onMainActor` (which asserts it is on the main thread and calls a `@MainActor` closure
synchronously; `MainThread.swift:8`). All animation playback happens in the render server.

**Lifecycle.** `WallpaperManager.addScene(to:)` creates one per window when the CD scene first
appears (`WallpaperManager.swift:356`), and again for every window in `rebuildWindows`. It goes
away either by `leave(then:)` → `removeFromSuperview()` when the scene ends, or by its window being
ordered out and `scenes = []` on a window rebuild. Closures that outlive a call (`asyncAfter`,
`renderPrint` completion) capture `self` weakly, so a removed scene is not kept alive by pending
work. The one exception is the closure `leave` passes to `done()`: it is the caller's closure, which
captures the scene strongly for at most 1.15 s so that it can remove it.

**Stored state.**

| Property | Type | Meaning |
|---|---|---|
| `stage` | `CALayer` (let) | Parent of `ambient` and `runners`. One of the two layers whose clock `updateClock` stops |
| `discStage` | `CALayer` (let) | Parent of holders and `sheen`; `zPosition = 10`. The second paused clock |
| `ambient` | `AmbientLayer` (let) | The soft colour glow behind the disc (see the ambient-fill chapter) |
| `holder` | `CALayer` (var) | The current disc's carrier: bounds = disc square, shadow, slides on changes |
| `disc` | `CALayer` (var) | The current disc's printed, spinning layer |
| `sheen` | `CAGradientLayer` (let) | The rainbow luster over the disc's inner part; does not spin |
| `runners` | `CALayer` (let) | Container for the running animals and chibis |
| `topInset`, `bottomInset` | `CGFloat` (let) | Menu-bar strip height and Dock height for this screen; the disc is centred in the space between |
| `cover` | `CGImage?` | The current cover as a CGImage |
| `print` | `CGImage?` | The current cover's disc print from `DiscPrint`, once made. The name shadows Swift's global `print(_:)` inside the class |
| `printJob` | `Int` | Generation counter for print renders. Only the newest render's result is applied |
| `changing` | `Bool` | A disc change is in progress |
| `changes` | `Int` | Counts disc changes; lets the 3 s safety timer know whether "its" change is still the current one |
| `queued` | `DiscDirection?` | A song that arrived during a change. Only the direction is kept; the cover is already in `cover` |
| `palette` | `AmbientPalette` (`private(set)`) | Glow colours derived from the cover's edges; read by `WallpaperManager` for the clock's tone |
| `discRect` | `CGRect` (`private(set)`) | Where the disc is, in view coordinates (y up); `.zero` before the first layout |
| `running` | `Bool` | Whether animations play. `didSet` calls `updateClock()` when it changes |
| `sides` | `NowPlayingSides` (let) | The side gear subview |
| `meterSource` | `AudioLevels?` | Forwarded to `sides` (live VU levels) |
| `lively` | `Bool` | False in Battery Saver. `didSet` rebuilds the scene with `layoutScene(force: true)` |
| `grabbedAt` | `CGFloat` | Disc rotation (radians) at the moment it was grabbed |
| `laidOut` | `CGSize` | The size `layoutScene` last built for, so it skips identical sizes |

### Small forwarding members

- **`running`** (`:29`) — `didSet` calls `updateClock()` only if the value changed. Set by
  `WallpaperManager` to `desktopVisible` (`WallpaperManager.swift:42, 358, 511`). Note that the
  manager ties it to desktop visibility, not to whether music is playing, even though the doc
  comment at `:8` says "everything stops when the music … pauses".
- **`meterSource`** (`:31`) — forwards the `AudioLevels` tap to `sides.meterSource`.
- **`levelsChanged()`** (`:32`) — forwards to `sides.levelsChanged()`, which restarts the gear's
  motion (live meters vs its own idle animation).
- **`gear`** (`:34`) — the side gear, or `nil` while `sides` is hidden (no song info). It has two
  readers. `WallpaperManager.gear` collects it from every canvas and scene to show the deck state
  (volume, tone knobs, repeat, shuffle) and to decide where click catchers go. `GearControls`'
  disc catcher calls `scene.gear?.scrub(by:angle:)` while you turn the disc, so the side panel's
  clock previews the time you are scrubbing to.
- **`setSong(_:animating:)`** (`:63`) — hides `sides` when `info` is nil, passes `animating`
  (desktop visible), and calls `sides.show(info)` to update title, artist and progress.

### `init(frame:artwork:topInset:bottomInset:)` (`:71`)

Steps:

1. Stores the insets and converts the `NSImage` to a `CGImage` with
   `cgImage(forProposedRect:context:hints:)`, which picks the best representation.
2. Computes `palette`. `cover.flatMap { FrameSampler($0) }` draws the cover into a 64×64 sRGB
   bitmap, `AmbientPalette.from` averages eight 12 %-wide edge strips and darkens them into
   "mood" colours, and `.neutral` (dark violet-grey) is the fallback if there is no image.
3. `super.init(frame:)`, `wantsLayer = true`, black background on the backing layer.
4. Builds the static part of the tree. `stage` goes on the backing layer, `ambient` goes in
   `stage` and shows the palette, and an empty `holder` goes in `discStage` as a placeholder (the
   real disc needs a size, so `layoutScene` builds it).
5. Sets up `sheen`. It is a conic gradient whose `startPoint` is the centre and whose
   `endPoint` (0.5, 1) is straight up in unit coordinates. For a conic gradient, the line from
   start to end sets the angle where the sweep begins. Its 25 colours come from `lusterColors()`.
6. Adds `runners` to `stage`. Adds `sides` as a subview that autoresizes with the view, hidden
   until a song is set.
7. Puts `discStage` on top (`zPosition = 10`) and calls `layoutScene(force: true)`.

At init the view has no window yet, so `window?.backingScaleFactor` is nil throughout this first
layout, and the code falls back to 2 (see Notes).

### `layoutScene(force:)` (`:432`) — building the scene for a size

This is the main builder. It runs at init, from `setFrameSize(_:)` (`:425`, which calls it with
`force: false`), and when `lively` changes (`force: true`).

```swift
let area = CGRect(x: 0, y: bottomInset, width: bounds.width, height: bounds.height - topInset - bottomInset)
let side = min(area.height * 0.66, area.width * 0.46)
discRect = CGRect(x: area.midX - side / 2, y: area.midY - side / 2 + area.height * 0.03, width: side, height: side).integral
```
(`MusicScene.swift:439-441`)

**Geometry.** `area` is the screen minus the menu-bar strip at the top and the Dock at the bottom
(y-up, so the Dock's height becomes `y: bottomInset`). The disc's diameter is 66 % of that height
or 46 % of the width, whichever is smaller. On a 16:10 laptop (1512×982 pt with a 38 pt menu bar
and no Dock inset) `area.height` is 944. That gives `side = min(623, 695) = 623` pt, which leaves
about 444 pt on each side for the gear panels. The disc is centred and nudged up by 3 % of the
area height, so it sits a little above optical centre. `.integral` rounds the rect outwards to whole
points so the edges land on pixel boundaries.

Steps, all inside one `CATransaction` with actions disabled:

1. Bails out unless `force` or the size changed, and unless `bounds.width > 0`. Records `laidOut`.
2. Sizes `stage` and `discStage` to `bounds`.
3. Computes `discRect`, then `ambient.arrange(in:around:)` places the four glow blobs in the side
   bars and `ambient.animated = lively` turns their drift on or off. `sides.lively = lively`
   and `sides.place(around: discRect)` lay out the gear panels in the space left and right of the
   disc.
4. Builds a fresh disc with `makeDisc(side:)`, swaps it in with
   `discStage.replaceSublayer(holder, with:)`, stores both layers with a tuple assignment, and starts
   its spin with `addSpin`.
5. Starts `renderPrint(side:)` for this size. Until the print arrives, `makeDisc` has already put
   the old print (wrong size, but disc-shaped) or the raw cover on the disc. When the new print
   arrives, `showPrint(on: self.disc)` puts it on whichever disc is current then.
6. Sets `sheen.frame = discRect` and gives it a new radial-gradient mask (next section).
7. Removes any `"sway"` animation and, if `lively`, adds a new one.
8. Removes all runner layers and, if `lively`, adds a new cast on the ground line
   `bottomInset + 18`.
9. Commits, then `updateClock()` (so a scene built while paused stays paused, or vice versa).

Rebuilding the whole disc on resize is simple and correct, because the masks, shadow path and print
are all size-dependent. Resizes are rare (screen resolution changes, the Dock moving), so the cost
does not matter.

#### The luster mask and sway

```swift
lusterMask.type = .radial
lusterMask.startPoint = CGPoint(x: 0.5, y: 0.5)
lusterMask.endPoint = CGPoint(x: 1, y: 1)
lusterMask.colors = [NSColor.clear, .clear, .white, .white, .clear].map(\.cgColor)
lusterMask.locations = [0, CD.hole, CD.hole + 0.01, CD.luster * 0.65, CD.luster].map { NSNumber(value: Double($0)) }
```
(`MusicScene.swift:459-464`)

For a radial `CAGradientLayer`, `startPoint` is the centre and `endPoint` gives the radii: the
horizontal and vertical distances from start to end, times the layer's width and height. Here
those are 0.5 × side, the disc radius, so gradient location 1.0 is the rim and every location is a
fraction of the radius. That is the same unit as `CD`. A mask uses only alpha. The sheen is
invisible inside the hole (0–0.09), jumps to full at 0.10, stays full to 0.28 and fades to zero at
0.43. So the shine covers the silver ring and the inner part of the print, the way the bright
reflective zone of a real CD sits near the hub.

The sway is a `CAKeyframeAnimation` on `transform.rotation.z` with values
`[0, 0.16, -0.08, 0.1, 0]` radians (at most about 9°), `calculationMode = .cubic` for a smooth
spline through the points, 16 s per cycle, repeating forever, at 10–20 fps (15 preferred). With
`keyTimes` unset, the five values are spaced evenly. The streaks drift back and forth "as the light
shifts". A layer's mask is transformed with the layer, so the mask rotates too, and because it is
radially symmetric it looks the same.

### `lusterColors()` (`:401`) — the rainbow with two glints

Returns 25 `CGColor`s for angles 0°, 15°, …, 360° (the last one repeats the first, so the conic
sweep closes without a seam).

```swift
func streak(_ center: Double) -> Double {
    let d = abs((angle - center + 540).truncatingRemainder(dividingBy: 360) - 180)
    return exp(-d * d / (2 * 16 * 16))
}
let glint = max(streak(35), streak(215))
```
(`MusicScene.swift:404-408`)

`d` is the shortest angular distance between `angle` and `center`. Adding 540 (= 360 + 180) keeps
the operand positive. The `truncatingRemainder` maps it into [0, 360), and subtracting 180 gives
a signed difference in [−180, 180). `exp(-d²/(2σ²))` with σ = 16° is a Gaussian bump. Two bumps at
35° and 215° (opposite each other, as reflections off concentric tracks are) give `glint` ∈ [0, 1].

Each colour has hue `angle/180 mod 1`, so the spectrum goes round *twice* per revolution, as on a
real disc where opposite sides diffract the same colours. Saturation is `0.55 − 0.3·glint`, so the
glints are whiter. Brightness is 1, and alpha is `0.1 + 0.4·glint`. The result is a faint rainbow
everywhere and two brighter, paler streaks.

### `makeDisc(side:)` (`:318`) — one CD

Returns `(holder, disc)`. `r = side/2` and `c = (r, r)` is the centre in the holder's own bounds.

- **`holder`**. Bounds are the disc square, and `position` is the centre of `discRect` (in
  `discStage` coordinates, which equal the view's). It carries the drop shadow: black, opacity
  0.55, blur radius 30, offset (0, −12), which is 12 pt *down* because layer space is y-up here. Its
  `shadowPath` is `ring(c, outer: r, inner: r·0.09)`. A shadow path saves Core Animation from
  computing the shadow from the composited alpha of the sublayers, which is expensive and would
  happen every frame because the disc spins. It also stops the hole from casting a shadow.
- **`mirror`**. A conic `CAGradientLayer` with nine greys
  `[0.82, 0.58, 0.95, 0.62, 0.88, 0.55, 0.93, 0.6, 0.82]` round the circle. The uneven light and
  dark sectors read as brushed metal catching light. It is masked to `ring(c, outer: r·0.22, inner: r·0.09)`
  through `shape(_:in:)`. It does not spin. A conic grey pattern turning would look wrong, and a
  real hub's reflection stays put relative to the light.
- **`edges`**. A `CAShapeLayer` whose path holds two circles (`addEllipse(in:)`) of radius
  `r·0.09` and `r·0.22`, stroked 1 pt white at alpha 0.32 with no fill. These are the hole's lip
  and the step between mirror and print.
- **`disc`**. A plain `CALayer` with `frame = bounds`. `showPrint(on:)` fills its contents.
  `contentsScale` is the window's backing scale (or 2), and it is masked to
  `ring(c, outer: r, inner: r·0.22)`. The print is already transparent outside that ring, so the
  mask is a second guarantee. It also keeps the raw-cover fallback (a square image) disc-shaped.

The sublayers are added in the order mirror, edges, disc. The disc is on top, but its mask leaves
the inner 0.22 open, so the mirror and edges show through there.

Rotating `disc` with `transform.rotation.z` rotates it around its `anchorPoint` (0.5, 0.5), the
disc's centre. A layer's mask is transformed together with the layer, and a ring is rotationally
symmetric, so the mask never visibly moves.

### `ring(_:outer:inner:)` (`:382`) and `shape(_:in:)` (`:392`)

```swift
p.addArc(center: c, radius: outer, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
p.closeSubpath()
p.move(to: CGPoint(x: c.x + inner, y: c.y))
p.addArc(center: c, radius: inner, startAngle: 0, endAngle: -2 * .pi, clockwise: true)
p.closeSubpath()
```
(`MusicScene.swift:384-388`)

An annulus as one `CGPath`: the outer circle wound one way, the inner circle the other.
`CAShapeLayer` fills with the non-zero winding rule by default, and shadow paths also use non-zero.
Under non-zero, a point inside both circles has winding number +1 − 1 = 0, so it is outside, and
the hole stays empty. (Even-odd would work whatever the winding. Opposite winding makes the path
correct under both rules, which is what the doc comment means by "wound so it works as a fill, a
mask or a shadow".) The explicit `move(to:)` before the inner arc stops `addArc` from drawing a
straight line from the outer circle's end to the inner circle's start. `shape(_:in:)` wraps a path in
a `CAShapeLayer` sized to `bounds`, for use as a mask.

### `showPrint(on:)` (`:358`)

Sets `disc.contents = print ?? cover`. If there is a print (already disc-shaped and square),
`contentsGravity = .resize` stretches it exactly to the layer. If not, the raw cover uses
`.resizeAspectFill`, which fills the square and crops a non-square cover centrally. The ring mask
then makes it round.

### `renderPrint(side:then:)` (`:364`) — the background print job

```swift
printJob += 1
let job = printJob
guard let cover else { apply(nil); return }
let pixels = Int((side * (window?.backingScaleFactor ?? 2)).rounded())
let inner = Double(CD.print)
DispatchQueue.global(qos: .userInitiated).async {
    let image = DiscPrint.make(from: cover, side: pixels, inner: inner)
    DispatchQueue.main.async {
        onMainActor { [weak self] in
            guard let self, self.printJob == job else { return }
            apply(image)
```
(`MusicScene.swift:365-375`)

- **Generation counter.** Each call bumps `printJob`. A completion applies only if no newer call
  has been made since. Fast song skipping, a resize mid-render, or a repaint right after a change
  therefore never let an older, slower print overwrite a newer one. The flip side is that a
  superseded `changeDiscs` render never calls its `apply`, so its `swapDisc` never happens. The 3 s
  safety timer in `changeDiscs` covers that case (see below).
- **Pixel size.** Points × backing scale gives a 1:1 pixel print, so a 623 pt disc on a Retina
  screen is a 1246×1246 bitmap.
- **Sendability.** The closure captures `cover` (an immutable, thread-safe `CGImage`), `pixels`,
  `inner` and `job`, but not `self`. The `self` capture appears only in the main-queue hop, and it
  is weak.
- **No cover.** `apply(nil)` runs synchronously. In `changeDiscs` that means `swapDisc` runs at
  once and the new disc shows `print ?? cover` = nil, an empty disc. It cannot happen in practice,
  because callers always pass an image that converts.

### `addSpin(to:)` (`:414`) — the steady turn

```swift
spin.byValue = -2 * Double.pi // clockwise, like a record
spin.duration = lively ? 14 : 30
spin.repeatCount = .infinity
spin.isRemovedOnCompletion = false
spin.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
```
(`MusicScene.swift:417-421`)

It first removes any existing `"spin"`. A `byValue`-only basic animation goes from the layer's
current value to current + `byValue`. That property is what makes `releaseDisc` work: after
`grabDisc`/`turnDisc` set the model transform to some angle θ, the new spin turns from θ, not from
0. Negative rotation about z is clockwise on screen in a y-up layer. One turn takes 14 s (about
4.3 rpm, a gentle pace far below a real CD's 200–500 rpm) or 30 s in Battery Saver. At 30 fps and
14 s per turn, each frame advances about 0.86°, which looks smooth for a slow rotation.
`isRemovedOnCompletion = false` is redundant with infinite repetition, but harmless.

### Hand spinning: `grabDisc()`, `turnDisc(by:)`, `releaseDisc()` (`:41-62`)

`GearControls.discCatcher` (`GearControls.swift:146`) puts an invisible round `NSPanel` over
`discRect` (converted to screen coordinates), above Finder's icons. Its handlers are:

- **mouse down** → `scene.grabDisc()`, plus a scratch sound starts.
- **drag** → `turn.move(to:)` accumulates the signed angle swept around the catcher's centre
  (`atan2`, unwrapped across ±π). Then `scene.turnDisc(by: turn.total)`, and
  `scene.gear?.scrub(by: −total/2π × 8 s)`: a full counter-clockwise turn rewinds 8 s, a clockwise
  turn advances 8 s.
- **mouse up** → `scene.releaseDisc()`, `gear.endScrub()`, and if the scrub is over 0.2 s, a
  `.scrub(seconds:)` command to Music.

`grabDisc()` reads the on-screen angle with
`disc.presentation()?.value(forKeyPath: "transform.rotation.z")`. Core Animation's key-path
extension pulls the z-rotation out of the presentation transform, and that includes the running
spin and any additive `spinUp`. Then, inside a no-actions transaction, it removes `"spin"` and
`"spinUp"` and writes the angle into the model transform. With the animations gone, the model value
is what shows, so the disc stops exactly where it was with no jump. `grabbedAt` remembers the angle.

`turnDisc(by:)` sets the model transform to `grabbedAt + angle`, again without implicit
animation. `angle` follows the maths convention (counter-clockwise positive), which in this y-up
layer space is also counter-clockwise on screen. The disc follows the hand at whatever rate mouse
events come in, which is up to the display rate and independent of the frame-rate ranges.

`releaseDisc()` calls `addSpin(to: disc)`, which continues clockwise from the released angle.

```
     ┌──────── spinning (spin, maybe spinUp) ◄───────────┐
     │ grabDisc: read presentation angle → model          │ releaseDisc:
     ▼          remove spin/spinUp                         │ addSpin (byValue from model angle)
  held still ── turnDisc(by:) → model = grabbedAt + angle ─┘
```

### Song changes: `setArtwork(_:direction:)`, `changeDiscs(_:)`, `changeFinished()`

`setArtwork` (`:108`) is called for a *different* song's cover. Steps:

1. Converts the cover, recomputes `palette` and tells `ambient` (which cross-fades its blobs
   over 2.5 s if the palette differs noticeably).
2. If the scene has never been laid out (`discRect.width == 0`), it puts the cover straight on the
   disc and returns.
3. If a change is under way, it records `queued = direction` and returns. Only the direction is
   queued. `cover` was already replaced in step 1, so whatever runs next prints the newest cover.
   However many songs go by during a change, only one more change happens, and it shows the latest
   one. The comment explains why not to start a second change at once: "two changes at once would
   fight over the same disc" (both would treat `holder`/`disc` as the outgoing pair).
4. Otherwise `changeDiscs(direction)`.

`changeDiscs` (`:121`):

```swift
changing = true
changes += 1
let change = changes
DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
    guard let self, self.changing, self.changes == change else { return }
    self.changeFinished()
}
renderPrint(side: discRect.width) { [weak self] image in
    self?.print = image
    self?.swapDisc(direction)
}
```
(`MusicScene.swift:122-134`)

The new disc does not leave until its print is ready (tens of milliseconds), so what slides in is
already the finished disc. The 3 s safety timer handles the case where `renderPrint`'s completion is
dropped because a newer print job (from `layoutScene` or `repaint`) superseded it. Without it,
`changing` would stay true forever and every later song would just be queued. The
`changes == change` check makes the timer a no-op if a later change is now running.

`changeFinished()` (`:138`) clears `changing`. If a direction was queued, it clears the queue and
starts that change.

```
           setArtwork (changing == false)
 idle ───────────────────────────────────────► rendering print ──(print ready)──► swapping
  ▲                                               │  setArtwork → queued = dir       │ setArtwork → queued = dir
  │                                               │  (superseded? 3 s timer)         │
  │                    changeFinished, queued == nil                                 │ +1.5 s (or +0.45 s hidden)
  └──────────────────────────────────────────────────────────────────────────────────┘
                         changeFinished, queued != nil → changeDiscs(queued) → rendering print
```

### `swapDisc(_:)` (`:215`) — the changer animation

Steps:

1. Remembers `oldHolder`. In a no-actions transaction it builds a new pair with `makeDisc`,
   inserts the new holder *above* the old one in `discStage` (so the incoming disc is on top
   where they overlap), and starts its spin. Then it makes the new pair current.
2. Computes `now = newHolder.convertTime(CACurrentMediaTime(), from: nil)`, the current time in
   the layer's own timeline. This matters because `discStage`'s clock is shifted every time the
   scene is paused and resumed. A `beginTime` of `CACurrentMediaTime() + 0.35` would be wrong after
   any pause.
3. **Not running** (desktop hidden): there is no slide. The new holder fades in over 0.4 s, and
   after 0.45 s the old holder is removed and `changeFinished()` is called. (The stage's clock is
   frozen while not running, so the fade waits at its first frame and plays when the scene resumes.
   The old holder has already gone by then. See Notes.)
4. **Running**: the off-screen x positions are
   `left = −side/2 − 60` and `right = bounds.width + side/2 + 60`, the disc centre placed
   60 pt beyond either edge, so the disc and most of its 30 pt shadow blur are off screen.
   `.forward` exits left and enters from the right. `.backward` (Previous) does the opposite.
5. **Out** (old holder, group, 0.8 s, `fillMode .forwards`, not removed): `position.x` → exit,
   `transform.scale` → 0.9, opacity keyframes `[1, 1, 0]` at `[0, 0.45, 1]` (it stays opaque for
   the first 45 % of the time, then fades). The timing curve (0.55, 0, 0.9, 0.5) is an ease-in that
   accelerates away. The old disc keeps spinning throughout, because its `"spin"` is on its `disc`
   sublayer and the group moves the holder.
6. **In** (new holder, group, 1.0 s, starting at `now + 0.35`, `fillMode .backwards`):
   `position.x` from entry to the centre, scale 0.9 → 1, opacity `[0, 1, 1]` at `[0, 0.4, 1]`.
   The timing curve (0.15, 0.85, 0.3, 1) is a strong ease-out with no overshoot. `.backwards` makes
   the delayed animation's first frame (off screen, invisible) apply during the 0.35 s wait, so the
   new disc does not flash at its model position (the centre) before it starts.
7. **Spin-up** on the new `disc`: an additive `transform.rotation.z` from 0 to −2.6 rad (forward)
   or +2.6 rad (backward), 1.4 s, ease-out, also starting at `now + 0.35`. Added on top of the
   steady spin, it makes the disc arrive turning faster and settle to normal speed. In reverse it
   "rewinds" as it arrives. Ease-out means the extra angular speed is highest at the start and
   decays to zero, so the hand-off to the plain spin is smooth. The animation has no fill mode and is
   removed when it ends, and its final additive value would be ±2.6 rad. Removing it therefore makes
   the print jump by 2.6 rad (about 149°) when it ends at 1.75 s. The disc's print is a busy image, so
   the jump would be visible. See Notes.
8. **Luster dip.** `sheen` gets opacity keyframes `[1, 0, 0, 1]` at `[0, 0.2, 0.7, 1]` over 1.2 s.
   The light's reflection fades out quickly, stays off while the discs travel, and returns as the
   new one settles. (The `for l in [sheen]` loop over a single element looks like it once covered
   more layers.)
9. After 1.5 s (wall clock) it removes the old holder and calls `changeFinished()`.

All of these request 30–60 fps (60 preferred), because the moves are short and fast and a low rate
would visibly stutter. Once they end, only the 15–30 fps spin and slow ambient work remain.

#### Timeline of a forward change (Next)

```
t (s)   0.0     0.35    0.36    0.8     1.2     1.35    1.5     1.75
        │       │               │       │       │       │       │
old     ├── slides LEFT, scale 1→0.9, accelerating ──┤ (held off-screen, opacity 0)
holder  │ opaque ──── 0.36 ────► fades 1→0 ─────────┤        removed at 1.5 ┤
        │       │                                    │
new     │ hidden│◄── enters from RIGHT, 0.9→1, ease-out ──────────────────►│1.35 at centre
holder  │(backwards fill)  opacity 0→1 by 0.75 ─►    │                     │
        │       │                                                          │
new     │       ├── spinUp: extra −2.6 rad (clockwise), easing out ────────────────────┤1.75
disc    │ spin (steady clockwise, 14 s/turn) running from t=0 ─────────────────────────────►
        │
sheen   ├─fade─┤0.24 ─────── off ─────────────┤0.84 ── back ──┤1.2
        │
state   changing = true ─────────────────────────────────────────────────┤ 1.5 changeFinished()
```

*(The swap starts when the print is ready, a few tens of ms after `setArtwork`. Times are measured
from `swapDisc`.)*

#### Timeline of a backward change (Previous)

```
t (s)   0.0     0.35            0.8             1.35    1.5     1.75
old     ├── slides RIGHT, 1→0.9, fades after 0.36 ──┤             removed 1.5
new     │ hidden├◄── enters from LEFT, 0.9→1 ─────────────────────┤
new disc│       ├── spinUp +2.6 rad (counter-clockwise "rewind"), easing out ──────────┤
sheen   ├ dip 1→0 ──── 0 ──── 0→1 ┤1.2
```

How the direction is chosen: `AppDelegate.noteDirection()` (`AppDelegate.swift:262-276`) keeps a
history of up to 50 recent songs. If the new song equals the second-to-last entry, the user went
back, so it pops the last entry and sets `wallpaper.discDirection = .backward`. Otherwise it appends
and sets `.forward`. `WallpaperManager` passes `discDirection` to `setArtwork` and `arrive`.

### `repaint(with:)` (`:203`) — same song, sharper art

Music often supplies a small cover first and a full-resolution one later. `WallpaperManager.setScene`
tells the two cases apart by comparing `"title|artist"` with the song whose cover is on the CD
(`WallpaperManager.swift:284`). For the same song it calls `repaint`, which updates `cover`,
`palette` and `ambient` and renders a new print. When the print arrives it puts it on the current
disc with `showPrint`. No disc change, no slide. `disc` is a standalone layer (it does not back a view), and the
assignment happens in a main-queue callback outside any no-actions transaction, so Core Animation's
default implicit action for `contents` applies: the low-res print cross-fades to the high-res one
over about 0.25 s. The same is true of the print that arrives after `layoutScene`.

### `arrive(from:)` (`:147`) — the scene's entrance

Called once, right after `addScene` adds the view. The view's `alphaValue` goes from 0 to 1 over
0.35 s through `NSAnimationContext` and `animator()`, AppKit's view-level animation proxy, which
for a layer-backed view animates the backing layer's opacity. If running and laid out, the holder
gets a 1 s group: `position.x` from beyond the right edge (`.forward`) or the left edge
(`.backward`) to the centre, plus scale 0.9 → 1, with the same ease-out curve and 30–60 fps as a
swap's entrance. There is no fill mode and no delay, so the group starts at once and leaves nothing
behind when it ends. The model position is already the centre.

### `leave(then:)` (`:172`) — the scene's exit

Called by `WallpaperManager.setScene` when the CD scene is no longer wanted. It runs only once the
replacement video is actually showing (`whenVideoShows`, polling up to 4 s), so your own paused
wallpaper never flashes in between. The local `fade` closure animates `alphaValue` to 0 over 0.45 s
and calls `done()` after 0.5 s. If not running (or not laid out), only the fade runs. Otherwise:

- the holder gets an 0.8 s group: `position.x` → `−side/2 − 60` (always to the left, whatever
  the direction) and scale → 0.9, with the accelerating ease-in, held with
  `.forwards` + `isRemovedOnCompletion = false` so the disc does not snap back to the centre
  before the view fades;
- `sheen` fades to 0 over 0.3 s and stays there;
- after 0.65 s the view fades (0.45 s), and `done()` runs at 1.15 s. In WallpaperManager `done()`
  is `removeFromSuperview()`.

Because the leaving scene is under the new content (or a new scene added on top), the fade reveals
what is already playing underneath.

### Runners: `addRunners(groundY:)` (`:487`)

Built only when `lively`. The cast:

- five animals picked at random from ten emoji (`🐕 🐈 🐇 🐿️ 🦔 🐁 🐧 🐥 🐖 🐢`), each rendered by
  `Sprites.emoji(_, size: 64)`, displayed 46–62 pt wide (random), marked `facesLeft: true` (Apple's
  emoji animals mostly face left), speed factor 1, except the tortoise at 0.45;
- two chibis from `Sprites.chibi`: pink hair, blue outfit, cat ears, 78 pt, speed 0.8; and dark
  violet hair, yellow outfit, no ears, 74 pt, speed 0.9. Both face right (`facesLeft: false`).

The cast is shuffled again and enumerated. For runner `i`:

| Layer | Job |
|---|---|
| `runner` | crosses the screen (`position.x` animation); opacity 0.92 |
| `hopper` | hops (`transform.translation.y`) and waddles (`transform.rotation.z`) |
| `sprite` | holds the picture (`contentsGravity .resizeAspect`, `contentsScale 2`), mirrored with `scale(−1, 1, 1)` if it would otherwise face backwards |

Three nested layers keep the three motions independent. Each one animates its own transform, so
none of them overwrites another's key path, and the mirroring stays separate from the waddle's
rotation.

- Direction alternates (`i % 2 == 0` runs rightward), and the sprite is mirrored when
  `facesLeft == rightward`.
- Lane: `groundY + (i % 3)·10 + height/2`, three lanes 10 pt apart, standing on
  `bottomInset + 18`, just above the Dock.
- **Cross**: `position.x` from just off one edge to just off the other, taking
  `bounds.width / (110 · speed)` seconds (110 pt/s, so about 13.7 s across a 1512 pt screen,
  30 s for the tortoise). It is wrapped in a group of length `across + random(6…22)` s that
  repeats forever, so each runner rests off screen for a random while between runs ("never a
  parade"). During the rest the group has no running child, so the runner falls back to its model
  position, off screen at `start`.
- **Stagger**: group `beginTime = CACurrentMediaTime() + i·5.5 + random(0…3)`.
- **Hop**: keyframes `[0, h, 0]` at `[0, 0.45, 1]`, ease-out up and ease-in down (a ballistic
  feel). `h` is 11 pt, or 3 pt for slow runners (`speed < 0.6`, the tortoise). The duration is
  random 0.34–0.48 s, or 0.9 s for the tortoise.
- **Waddle**: rotation −0.07 → 0.07 rad (±4°), `autoreverses`, same duration as a hop, so one
  full rock spans two hops.
- All runner animations ask for 20–30 fps.

Because the cast is re-rolled on every `layoutScene`, the characters change on resize and on a
Battery Saver round trip.

### Battery Saver: `lively` (`:69`)

`WallpaperManager.powerChanged` sets `lively = !PowerState.saving` on every scene. The `didSet`
rebuilds with `layoutScene(force: true)`, and the differences are:

| | lively (normal) | not lively (Battery Saver) |
|---|---|---|
| disc spin | 14 s / turn | 30 s / turn |
| luster sway | 16 s cycle | none (static) |
| ambient blobs | drifting | static colours (`ambient.animated = false`) |
| side gear | animated (`sides.lively = true`) | reduced (`NowPlayingSides` decides) |
| runners | 7 characters | none |
| disc change slides | yes | yes (unchanged) |

### Pausing: `updateClock()` (`:555`)

```swift
if running, layer.speed == 0 {
    let paused = layer.timeOffset
    layer.speed = 1
    layer.timeOffset = 0
    layer.beginTime = 0
    layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - paused
} else if !running, layer.speed != 0 {
    let now = layer.convertTime(CACurrentMediaTime(), from: nil)
    layer.speed = 0
    layer.timeOffset = now
}
```
(`MusicScene.swift:557-567`)

This is Apple's standard pause and resume recipe (Technical Q&A QA1673), applied to both `stage`
and `discStage`. A layer's local time is `(parentTime − beginTime) × speed + timeOffset`.

- **Pause**: read the current local time, set `speed = 0` and `timeOffset = now`. Local time is
  now constant at `now`, so every animation below shows the frame it had.
- **Resume**: remember the frozen time, restore `speed = 1` and `timeOffset = 0`, clear
  `beginTime`, then set `beginTime = parentTime − paused`. Local time = `parentTime − (parentTime − paused)`
  = `paused` at this instant, and it advances normally from there. Nothing jumps.

Because `swapDisc` uses `convertTime` to compute `now`, its delayed `beginTime`s are correct on the
shifted timeline. The view's own layer and `sides` are not under these two layers. `NowPlayingSides`
handles its own motion through `animating`.

### Tone readings for the clock

The desktop clock (a separate target) asks for the brightness behind it so it can choose light or
dark text (`ToneReporter`, its own chapter). For the CD scene, `WallpaperManager.sceneTone()`
(`WallpaperManager.swift:366`) reads two things from `MusicScene`:

- **`discRect`**, converted to screen fractions with y running down:
  `x = minX/w`, `y = (h − maxY)/h` (the flip from AppKit's y-up), `width = side/w`,
  `height = side/h`;
- **`palette.luma`**: the mean of the eight glow colours' Rec. 709 luma, × 0.8. That is the
  brightness reported everywhere outside the disc rect.

It then calls `tone.show(frame, visible: disc, full: disc, fill: palette.luma, force: true)` with a
64×64 `FrameSampler` of the full cover. Inside the disc rect, brightness is sampled from the cover
stretched over the square. Outside, it is the glow's estimate. It runs on every `setScene` change.
This is an approximation (see Notes). It ignores the disc's round cut (the corners of `discRect`
actually show glow), the hole and silver ring, and `DiscPrint`'s placement shift and zoom.

### `Sprites` (`:574`)

A `@MainActor` caseless enum (a namespace) with one stored static, `cache: [String: CGImage]`. It
draws each picture once per process and never evicts. With a dozen small images that is fine.

- **`emoji(_:size:)`** (`:577`) — returns the cached image keyed by the emoji text alone. Otherwise
  it lays the emoji out in "Apple Color Emoji" (falling back to the system font) at `size`, measures
  it with `NSAttributedString.size()`, draws it into a drawing-handler `NSImage` (drawn lazily at
  whatever scale is asked for), converts it with `cgImage(forProposedRect:…)`, caches and returns it.
  `cgImage(forProposedRect: nil…)` rasterises at the image's point size times the scale of the
  current context or main screen, so on Retina it is 2× the point size. The cache key ignores
  `size` (see Notes). Only one size is ever used.
- **`chibi(hair:outfit:catEars:)`** (`:592`) — an original character drawn with `NSBezierPath` in
  an 80×104 pt, y-up canvas, from back to front: two dark rounded-rect legs at the bottom, an
  A-line body (a trapezoid narrowing upward from y = 14 to 42), two skin-coloured oval hands, a big
  hair oval behind the head, optional triangular cat ears at x = 14 and 66 pointing outward, the
  face oval, zig-zag bangs (a path stepping across in 12 pt teeth that alternate between 68 and
  72 pt, closed across the top at 96), two eyes (a dark oval, a lighter lower iris in the hair
  colour blended 35 % toward white, and two white highlights), pink blush ovals at alpha 0.5, and a
  small curved mouth stroked 1.6 pt. The key is
  `"chibi \(hair) \(outfit) \(catEars)"`, using `NSColor`'s description. The `cgImage` result is
  force-unwrapped.

### `DiscDirection` (`:653`)

`.forward` (Next, the default: old disc leaves left, new arrives from the right) and `.backward`
(Previous: mirrored). It is used by `setArtwork`, `changeDiscs`, `swapDisc` (exit/entry sides and
spin-up sign), `arrive` (entry side), the `queued` slot, and `WallpaperManager.discDirection`.
`leave` ignores it and always exits left.

### Notes and risks

- `MusicScene.swift:283-291` — the additive `spinUp` (0 → ±2.6 rad) has no fill mode and is
  removed at the end. Its contribution drops from ±2.6 rad to 0 at once when it ends, so the print
  should visibly jump by about 149° 1.75 s after a change starts. A `fromValue` of ∓2.6 and
  `toValue` 0 (decaying to zero) would avoid the jump.
- `MusicScene.swift:208` vs `:131` — `repaint` bumps `printJob`, so if a sharper cover of the new
  song arrives while `changeDiscs` is still rendering, the change's completion is dropped. Then no
  swap happens, `repaint` puts the new song's print on the *old* disc without a slide, and
  `changing` stays true until the 3 s safety timer, with later songs held in `queued`.
- `MusicScene.swift:447` (`layoutScene`, also run on `lively` changes) during a change replaces the
  incoming holder with a static one and supersedes a pending change print. The disc pops in at the
  centre while the old one may still be sliding.
- `MusicScene.swift:496` — runner `beginTime` uses raw `CACurrentMediaTime()` while the runners
  live under `stage`, whose clock is shifted by every pause (`:562`). After the scene has been paused
  for N seconds, any rebuild (resize, Battery Saver toggle) delays the runners' first appearance by
  about N seconds more. `swapDisc` uses `convertTime` correctly (`:227`).
- `MusicScene.swift:228-238` — while not running, the new holder's 0.4 s fade is added to a paused
  timeline (it shows opacity 0 until resume), but the old holder is removed after 0.45 s of wall
  time. Nobody sees the screen meanwhile, but on resume the disc fades in from nothing rather than
  cross-fading.
- `MusicScene.swift:127-129` — if a print takes longer than 3 s, the safety timer calls
  `changeFinished`, a queued change can start, and the late print still calls `swapDisc` (its
  `printJob` may still match), so two swaps can overlap.
- `MusicScene.swift:302` — `oldHolder` removal and `changeFinished` use wall-clock `asyncAfter`,
  while the animations run on the pausable layer clock. A pause mid-change removes the old disc
  mid-slide.
- `MusicScene.swift:351, 368` — the backing scale is read from `window`, which is nil during the
  init-time layout, so the first print is rendered at 2× (and `contentsScale = 2`) on any screen.
  No `viewDidChangeBackingProperties` override re-renders after moving to a 1× or 3× screen. Only a
  size change does.
- `MusicScene.swift:147-167` — `arrive` slides the disc in but leaves `sheen` at full opacity over
  the centre, so for about a second the luster floats over an empty spot (unlike `swapDisc`, which
  dips it).
- `MusicScene.swift:20` — the property `print` shadows Swift's global `print(_:)` inside the class.
- `MusicScene.swift:8` vs `WallpaperManager.swift:511` — the doc says everything stops when the
  music pauses, but `running` follows only desktop visibility.
- `MusicScene.swift:578` — the `Sprites.emoji` cache key ignores `size`. A second size would get
  the first size's bitmap.
- `MusicScene.swift:646` — force-unwrap of `cgImage(...)!` in `Sprites.chibi`.
- `MusicScene.swift:294` — a single-element loop `for l in [sheen]`, left over from earlier code.
- `WallpaperManager.swift:367-372` — the tone reading maps the unplaced, square cover over the
  whole disc rect. It does not account for the round cut, the hub, or `DiscPrint`'s shift/zoom.

---

## Sources/Himawari/DiscPrint.swift

### What the file is for and where it sits

`DiscPrint.swift` (106 lines, imports CoreGraphics, Foundation, HimawariKit) is a caseless enum with
two static functions. It turns a cover into the image printed on the disc. Its only caller is
`MusicScene.renderPrint` (`MusicScene.swift:371`), on a global `userInitiated` queue. It uses
`FrameSampler` from HimawariKit (`WallpaperTone.swift:145`) for a small luma copy of the cover.

The doc comment states the intent. The art is laid *flat* across the disc (not warped round it, the
way an earlier "wrap" approach might), cut to the circle, stopped at the silver ring, with the
pressed tracks showing faintly through "the ink". It is also placed the way a disc designer would
place it, so the hole and hub fall on a calm part of the cover rather than on a face or the title.

**Design decisions.** The output is a finished, premultiplied RGBA bitmap at exactly the on-screen
pixel size. That makes the render server's job a plain textured quad, and it lets the soft
antialiased edges be computed analytically rather than relying on mask rasterisation. The work is
pure (no shared state), which makes it safe on any thread. The per-pixel loop is spread across all
cores with `DispatchQueue.concurrentPerform`. The doc comment claims about 10 ms for a
full-resolution disc.

**Threading.** `DiscPrint` holds no state and is `Sendable` by construction. `make` is called off
the main thread. Inside, `concurrentPerform` runs rows in parallel on GCD's worker threads. The
calling thread blocks until all rows are done.

### `make(from:side:inner:)` (`:18`)

Inputs: `cover` (any size or aspect), `side` (output edge in pixels), `inner` (where the print stops,
as a fraction of the radius; `CD.print` = 0.22). Output: a `side × side` sRGB `CGImage` with
premultiplied alpha, or nil.

Steps:

1. **Guard.** `side > 8` and an sRGB colour space, else nil.
2. **Placement.** `placement(of:inner:)` returns `center` (a point on the cover, 0…1, y down) and
   `zoom` (≥ 1).
3. **Draw the cover.** It allocates `out = [UInt8](repeating: 0, count: side·side·4)` and wraps it
   in a `CGContext` (8 bits per component, `premultipliedLast` = RGBA with alpha last, high
   interpolation) through `withUnsafeMutableBytes`, so Core Graphics writes straight into the Swift
   array.

   ```swift
   let scale = Double(side) / Double(min(cover.width, cover.height)) * place.zoom
   let w = Double(cover.width) * scale, h = Double(cover.height) * scale
   // `place.center` (a point on the cover, y down) lands on the disc's center.
   ctx.draw(cover, in: CGRect(x: Double(side) / 2 - place.center.x * w,
                              y: Double(side) / 2 - (1 - place.center.y) * h, width: w, height: h))
   ```
   (`DiscPrint.swift:28-32`)

   The geometry: `scale` makes the cover's *short* side equal the disc diameter, times `zoom`, so
   the disc is always fully covered (aspect fill). Core Graphics contexts are y-up, so a point
   `center.y` from the top of the cover is `(1 − center.y)·h` from its bottom. Placing the rect's
   origin at `side/2 − center.x·w`, `side/2 − (1 − center.y)·h` puts that cover point exactly at the
   disc centre `(side/2, side/2)`. The memory layout: a bitmap context's first row in memory is the
   *top* of the image when it becomes a `CGImage`, which matches the y-down convention used for
   `center`.
4. **Cut and press, per pixel, on all cores.**

   ```swift
   let c = Double(side) / 2
   let feather = 1.2 / c                    // about a pixel of antialiasing at each edge
   let trackPitch = Double(side) / 260      // ~130 visible tracks across the print
   ...
   let r = (dx * dx + dy * dy).squareRoot() / c
   let coverage = min(max((1 - r) / feather, 0), 1) * min(max((r - inner) / feather, 0), 1)
   ```
   (`DiscPrint.swift:38-48`)

   For pixel centre `(x + 0.5, y + 0.5)`, `r` is the distance from the disc centre normalised to the
   radius (0 at the centre, 1 at the rim). `coverage` multiplies two linear ramps. The outer one is
   1 inside the rim and falls to 0 over `feather` (1.2 px, since `feather` is 1.2/c in normalised
   units) just inside `r = 1`. The inner one rises from 0 at `r = inner` to 1 at 1.2 px further
   out. The result is an antialiased annulus with no supersampling. Pixels with zero coverage are
   cleared to transparent black and skipped.

   **Tracks**: `ripple = 1 − 0.035·(0.5 + 0.5·sin(2π · r·c / trackPitch))`. `r·c` is the radius in
   pixels, and dividing by `trackPitch` (side/260 px) counts tracks, so there are 130 full sine
   periods from the centre to the rim whatever the resolution. The brightness dips between 0 and
   3.5 %, a faint concentric texture like pressed grooves showing through a printed label. On a
   1246 px disc the pitch is about 4.8 px, wide enough not to alias into moiré at 1:1 display.

   **Premultiplied write**: RGB channels are multiplied by `coverage × ripple`, alpha by
   `coverage` only. With premultiplied alpha, colour must already be scaled by alpha, so scaling
   RGB by coverage keeps the pixel valid, and the extra `ripple` factor darkens the colour without
   making it more transparent.

   `DispatchQueue.concurrentPerform(iterations: side)` runs one iteration per row on as many threads
   as there are cores. Each row writes only its own bytes (`(y·side + x)·4 …`), so the writes never
   overlap and need no locking. The buffer is reached through `withUnsafeMutableBufferPointer`. That
   is valid because `concurrentPerform` returns only when every iteration has finished, inside the
   closure's lifetime.
5. **Wrap as an image.** `Data(out)` copies the bytes into a `CFData` for a `CGDataProvider`. Then
   `CGImage(width:height:bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side·4, space: sRGB,
   bitmapInfo: premultipliedLast, provider:, decode: nil, shouldInterpolate: true, intent: .defaultIntent)`.
   `shouldInterpolate` lets Core Animation filter smoothly when it scales the image (for instance
   during the 0.9 → 1 scale of a slide).

**Performance.** Per pixel the cost is one square root, one sine and a handful of multiplies. For a
1246² disc that is about 1.55 M pixels, minus the transparent corners and hub (about 26 % of the
square lies outside the unit circle, and the hub removes another ~4 %). Spread over 8–10 cores
that comes to a few milliseconds. The other costs are the high-quality `ctx.draw` of the cover
(one resampling pass, done by Core Graphics on the calling thread), the serial placement search
(below), and the `Data(out)` copy. Peak memory is about twice the bitmap (6.2 MB × 2 for a 1246²
print) while the copy exists. A larger display (say a 1700 pt disc at 2×, 3400²) gives 46 MB per
copy, transiently.

### `placement(of:inner:)` (`:71`) — content-aware positioning

Returns `(center, zoom)`: which point of the cover (0…1, y down) goes under the disc's centre, and
how far to enlarge (1 = the cover's short side just fills the disc). The aim is to keep the hub
(hole, silver ring and a margin) off detailed areas such as text and faces, while staying near the
middle and not zooming unless it helps.

Steps:

1. **Sample.** `FrameSampler(cover, side: 64)` gives a 64×64 sRGB copy (aspect squashed to
   square, row 0 at the top). If that fails, it returns the centre and zoom 1.
2. **Luma grid.** `n = 48`. For each cell centre `((x+0.5)/48, (y+0.5)/48)`, `sample.luma(u, v)`
   gives Rec. 709 luma (0.2126 R + 0.7152 G + 0.0722 B) by nearest-neighbour lookup into the 64²
   copy.
3. **Edge map.** For interior cells a central-difference gradient,
   `gx = L[x+1] − L[x−1]`, `gy = L[y+1] − L[y−1]`, and `edges = √(gx² + gy²)`. Border cells stay 0.
   Gradient magnitude is a cheap stand-in for "detail": text, faces and texture give large values,
   while sky and flat colour give near zero.
4. **Search.** For `zoom` in 1.00, 1.05, …, 1.30 (7 values):

   ```swift
   let shownW = min(1, 1 / aspect) / zoom, shownH = min(1, aspect) / zoom
   let hubX = inner * shownW / 2 * 1.15, hubY = inner * shownH / 2 * 1.15
   ```
   (`DiscPrint.swift:86-88`)

   `shownW × shownH` is the part of the cover the disc's bounding square shows, in cover fractions.
   For a landscape cover (`aspect > 1`) the full height and `1/aspect` of the width are shown, and
   zoom shrinks both. The disc's radius in cover fractions is `shownW/2` horizontally and `shownH/2`
   vertically (an ellipse in fraction space, a circle in pixels, because the 64² sample squashes the
   aspect). The hub ellipse is `inner` times that, plus 15 % margin.

   For each of 11 × 11 candidate centres, `cx` runs from `shownW/2` to `1 − shownW/2` (and `cy`
   likewise), the full range that keeps the shown square inside the cover. For every grid cell
   inside the hub ellipse (`dx² + dy² ≤ 1` after dividing by the semi-axes), it sums `edges` and
   counts cells. The cost is

   `average edge under the hub + 0.25 · distance(center, (0.5, 0.5)) + 0.3 · (zoom − 1)`

   and the lowest cost wins (ties keep the earliest candidate, which is zoom 1 and the top-left in
   scan order). The penalties make the art move only when that clearly buys a calmer hub. For a
   calm cover every candidate has near-zero detail, so the unmoved, unzoomed placement wins.

   Worked numbers: at zoom 1 with a square cover, `shownW = 1`, so every `cx` equals 0.5 and all 121
   candidates are the same point. Movement is only possible with zoom > 1. At zoom 1.3,
   `shownW ≈ 0.77`, so the centre can move ±0.115 of the cover, and the hub ellipse has semi-axes
   `0.22 · 0.385 · 1.15 ≈ 0.097` (about 4.7 grid cells, about 70 cells covered). Moving the full
   0.163 diagonally costs 0.041, and zoom 1.3 costs 0.09, so it pays only if it lowers the mean edge
   strength under the hub by more than about 0.13 luma per two cells. That is a clearly visible
   difference, like moving off a title.
5. Returns the best `(center, zoom)`.

**Cost.** 7 × 121 = 847 candidates, each scanning all 2,304 cells (with an ellipse test per cell),
is about 1.95 M inner iterations, serial, on the calling queue. With simple arithmetic that is a
few milliseconds. Scanning only the bounding box of the hub ellipse (about 10×10 cells) would cut it
about 20 times. The placement depends only on the cover, not on `side`, yet it is recomputed on
every `make` call (each resize and each repaint).

### Data flow

```
NSImage ──cgImage──► CGImage cover ─┬─► FrameSampler 64² ─► luma 48² ─► edges 48² ─► search ─► (center, zoom)
                                    │                                                            │
                                    └────────────── CGContext draw (aspect fill × zoom, centred) ◄┘
                                                         │ RGBA premultiplied, side² px
                                                         ▼
                                  concurrentPerform rows: r, coverage(rim, inner), ripple → write
                                                         ▼
                                       Data copy ─► CGDataProvider ─► CGImage ─► disc.contents
```

### Notes and risks

- `DiscPrint.swift:84-91` — at zoom 1 with a square cover, all 121 candidates are the same point
  (`1 − shownW = 0`), so 120 of them are wasted work. Every candidate also scans all 48² cells
  rather than the hub's bounding box.
- `DiscPrint.swift:78-81` — border cells of the edge map are left at 0, which slightly favours
  candidates whose hub reaches the border (only possible with small `shownW`, rarely in practice).
- `DiscPrint.swift:71-72` — placement depends only on the cover but is recomputed for every size
  (`layoutScene`) and every repaint. Caching it per cover would save the search.
- `DiscPrint.swift:61` — `Data(out)` copies the whole bitmap. A `CGContext.makeImage()` from a
  context-owned buffer, or `Data(bytesNoCopy:)`, would avoid the second copy (up to tens of MB on
  large screens).
- `DiscPrint.swift:41-42` — writing through an `UnsafeMutableBufferPointer` captured by the
  `concurrentPerform` closure is correct (disjoint rows, synchronous join), but it sidesteps Swift
  concurrency checking. A future edit that writes across rows would race silently.
- `DiscPrint.swift:14-15` — the "about 10 ms" figure is a comment, not measured anywhere in the
  code or tests. The serial placement search and the cover draw are not parallelised.
- `DiscPrint.swift:28` — a cover with a 0 width or height would divide by zero. `CGImage` never
  has zero dimensions in practice.
