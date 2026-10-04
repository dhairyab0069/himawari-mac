# 10 · Health report: Betas 1.1.3 and 1.1.4 (4 October 2026)

This chapter records the state of the code at Beta 1.1.3: how it was checked, what was found, what
was fixed, how it performs, and what is still open. The other chapters describe the code as it is;
this one describes how it got there in this release.

## How the code was checked

| Check | How | Result |
|---|---|---|
| Compiler | `swift build -c release`, Swift 6.3, macOS 26.2 SDK | 0 errors, 0 warnings |
| Universal build | `UNIVERSAL=1 scripts/make_dmg.sh` | arm64 + x86_64; DMG 2.9 MB |
| Crash reports | `~/Library/Logs/DiagnosticReports` | none for Himawari or its clock |
| Log review | `~/Library/Logs/Himawari.log` (446 lines, 26 Sep – 4 Oct) | one recurring warning (the "silent tap", below) |
| Code review | every file read end to end, each finding traced to a concrete trigger | 8 findings, all fixed in 1.1.3 |
| Chapter authors | writing chapters 3–9 of this report meant reading every function; each chapter ends with *Notes and risks* | ≈ 120 notes; the user-visible ones fixed in 1.1.4 (below), the rest listed in the chapters |
| Live checks | Music played and paused while Himawari ran; audio-process listing via Core Audio; `top` and `sample` on the running app | 3 more findings, all fixed |

## Size of the code

| Part | Files | Lines |
|---|---|---|
| `Sources/Himawari` (the app) | 19 | 4,809 |
| `Sources/HimawariKit` (shared) | 11 | 1,711 |
| `Sources/HimawariClock` (clock helper) | 3 | 437 |
| `helpers/NowPlayingHelper.m` | 1 | 90 |
| Scripts and tools | 6 | 416 |
| **Total** | **40** | **≈ 7,460** |

## Findings and fixes

Severity: **High** breaks a feature or wastes significant battery; **Medium** breaks a feature in
a specific situation; **Low** a crash path or a rare edge case.

| # | Severity | Finding | Trigger | Fix |
|---|---|---|---|---|
| 1 | High | **Your video kept decoding under the CD scene and YouTube loops.** The watchdog restarted a paused player every 2 s without checking whether the CD (`sceneArt`) was showing; the muted-video loader also called `play()` unconditionally. | Any song without an animated cover. | Both paths now play only when neither the CD nor YouTube is showing (`WallpaperManager.swift`, watchdog and `start(_:)`). |
| 2 | High | **Volume 0 still decoded and output audio.** "Muted" and "volume 0" were different states; moving the slider to 0 un-muted, so the audio track was decoded (Core Audio listed Himawari as an active output, and `sample` showed an `AQConverterThread`). | Volume slider dragged to 0. | Volume below 0.5 % counts as muted, so the picture-only version plays. Measured: memory 70 MB → 38 MB, and Himawari no longer appears as an audio output. |
| 3 | High | **VU meters silent.** A Core Audio process tap made without the *System Audio Recording* permission doesn't fail: it delivers zeros. Nothing asked for the permission, so the meters could stay silent with no explanation. | First run, or permission never granted. | New `AudioPermission.swift` checks and requests the permission (TCC preflight/request, looked up at run time) before building a tap, and starts the meters as soon as it's granted. |
| 4 | Medium | **False "silent tap" warnings.** The tap is kept alive for 15 s after pausing (so window switches don't rebuild it) and hears silence then, which logged a permission warning. | Pausing a song. | The hearing check runs only while the song is playing. |
| 5 | Medium | **Gear and CD stopped responding after a screen change.** Click catchers were keyed by `ObjectIdentifier(view)`; a view rebuilt after a display change can reuse a freed view's address, so the old catcher (pointing at the freed view) was kept. | Plugging in a display, changing resolution. | Each gear view and CD scene has a stable `catcherKey` (a UUID). |
| 6 | Medium | **Two kinds of catcher window leaked.** The jog-wheel and disc catchers' closures captured their own window strongly. | Every rebuild of those controls. | `[unowned c]` captures. |
| 7 | Medium | **"No animated cover" cached for the whole session after a network failure.** Failed lookups looked the same as genuine "none" and were cached forever; YouTube searches likewise. | Starting a song just after waking, before Wi-Fi reconnects. | Empty results expire after 2 minutes; found results stay cached. |
| 8 | Medium | **Meters dead after Music relaunched.** The tap targets Music's process at start; if Music quit and came back within the 15 s grace, the old tap was reused. | Quitting and reopening Music while playing. | The tap remembers Music's process id and is rebuilt when it changes. |
| 9 | Medium | **No back-off for failing streams.** A stalled or failed animated cover was restarted every 1–2 s indefinitely. | Network drops during an animated cover. | Retries back off 1, 2, 4 … 30 s and reset once playback is healthy. |
| 10 | Medium | **Aerial conversion hazards.** (a) A source pass yielding no frames looped forever; (b) the existing good master was deleted before encoding and a failed run left a broken file; (c) turning the feature off mid-conversion could still swap files and save state. | A corrupt video; cancelling; turning off during the swap phase. | (a) A pass that writes nothing throws. (b) Encoding writes to `…partial.mov`, which is moved over the master only on success, and the writer is cancelled on failure. (c) Cancellation is checked before each swap and before saving state. |
| 11 | Low | **Moving Lock Screen not resumed or repaired.** The 6-hourly repair timer started only if the feature was on at launch; a conversion interrupted by quitting was never resumed. | Turning the feature on from the menu; quitting mid-conversion. | The repair timer starts whenever the feature is turned on (and stops when off); launch calls `apply`, which checks a finished copy or resumes an unfinished one. |
| 12 | Low | **Crash path in the desktop-click check.** `terminationStatus` was read from an `osascript` process that might never have launched, which raises an Objective-C exception. | `osascript` failing to start. | Status is read only after a successful launch. |

### Fixed in Beta 1.1.4

Found while writing this report (each chapter's *Notes and risks* has the full list).

| # | Severity | Finding | Fix |
|---|---|---|---|
| 13 | Medium | **The CD jumped ~150° at the end of every disc change.** The arrival spin was additive from 0 to ±2.6 rad and removed when done, so the disc snapped back (`MusicScene.swift`). | The spin now runs from ±2.6 rad to 0, so removing it changes nothing. |
| 14 | Medium | **Double-click "flat" on BASS / TREBLE didn't work, and a plain click switched Music's equalizer on.** Every mouse-up resent the knob's value, including the clicks of a double-click (`GearControls.swift`). | Only a drag sets the tone. |
| 15 | Low | **The VOLUME knob jumped mid-drag** when Music's real volume arrived after the drag began. | The drag starts from what the knob shows; a late answer is ignored once you're dragging. |
| 16 | Medium | **Meters tapped the wrong device** when the alert-sound device differs from Music's output (`kAudioHardwarePropertyDefaultSystemOutputDevice`). | Uses the default output device (where Music plays) and follows its changes. |
| 17 | Medium | **Pressing a gear button with the files hidden brought the files back.** The click-to-hide monitor treated the gear's click catchers as the wallpaper (`DesktopPeek.swift`). | Clicks on catcher panels are ignored. |
| 18 | Low | **Progress ladder full after a rebuild** until the seconds changed (stuck full while paused) (`NowPlayingSides.swift`). | The time display redraws whenever the ladder is rebuilt. |
| 19 | Low | **The Now Playing helper could crash** on a NaN or infinite number (JSON can't hold them) (`NowPlayingHelper.m`). | Non-finite values are skipped and every line is validated before writing. |
| 20 | Low | **Album-less songs shared one artwork answer** per artist (cache key `"artist|"`). | Keyed by song when there's no album. |
| 21 | Low | **YouTube ids went into JavaScript unchecked.** | Only 11-character `[A-Za-z0-9_-]` ids are accepted. |
| 22 | Low | **Moving Lock Screen leftovers:** a crash mid-conversion left a partial file `restore()` didn't remove; a repair swap couldn't be cancelled; repair re-converted a deleted video. | All three handled. |
| 23 | Medium | **REPEAT / SHUFFLE did nothing** until Music's settings had been read once (the action worked on an optional reading). | Reads them first if needed, then switches. |
| 24 | Low | **Turning on Moving Lock Screen left the still frame** as your desktop picture (the still option was switched off without restoring the previous picture). | The previous picture is restored. |
| 25 | Medium | **Regression caught before release:** the first fix for #17 ignored every panel, but the wallpaper's own windows are panels too, so clicking the wallpaper stopped bringing files back through that path. | Catcher windows carry an identifier and only they are ignored. |

## Performance (MacBook Air, macOS 26.2)

Measured with `top` and `ps` on the installed app; the desktop visible; Battery Saver off.

| State | CPU (Himawari) | Memory (Himawari) | Notes |
|---|---|---|---|
| Song playing, animated cover or CD showing | 0.3–1.2 % | ≈ 60 MB | Video decoding and animation happen in the window server and media services, not in this process. |
| Your own video showing (before fix 2) | ≈ 7 % | 50–70 MB | Audio track decoded although volume was 0. |
| Your own video showing (after fix 2) | ≈ 6 % right after launch, settling lower | ≈ 38 MB | Picture-only playback. |
| Desktop clock helper | 0.0 % | ≈ 25 MB | Wakes once a second (or minute) to tick. |

An Aerial conversion for the Moving Lock Screen is the one heavy task: about five times the Aerial's
length of full-CPU encoding (20–30 minutes for a 3.5-minute Aerial), once per video.

## Still open

- **Fallback to the CD after repeated stream failures.** Stream retries now back off, but an animated
  cover that never loads keeps the wallpaper on its last frame rather than switching to the CD scene.
- **Unofficial platform behaviour.** The system Now Playing stream (MediaRemote via `/usr/bin/perl`),
  Apple Music's album pages, the TCC lookup for the audio permission, and swapping Aerial videos are
  all undocumented. Each has a fallback or fails safe, but any macOS update can change them.
- **No automated tests.** Correctness rests on the compiler, logs and manual checks. The album-matching
  rules (`MotionArtwork.albumKey`, `sameAlbum`) and the gear's angle maths (`Turn`) are pure functions and
  would be the easiest first unit tests.
- **Not notarized.** Users must right-click ▸ Open the first time; notarization needs a paid Apple
  Developer ID.
