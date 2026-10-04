# 2 · Building, packaging and maintaining it

Himawari has no Xcode project. It is a Swift Package, and everything that turns the compiled
executables into a double-clickable, signed app (bundle layout, `Info.plist` files, the icon, the
Objective-C helper, the embedded clock app, signing, the DMG) is done by shell scripts. This
chapter goes through each of those files in the order a build runs them, then covers the weekly
maintenance job, `.gitignore`, and how versions and releases are made.

The overall pipeline:

```
 tools/make_signing_identity.sh  (once per Mac, optional)
            │ creates "Hanabi Local Code Signing" in the login keychain
            ▼
 Package.swift ──swift build -c release [--arch arm64 --arch x86_64]──▶ .build/…/Himawari, HimawariClock
            │
 build.sh ──┼─ tools/make_icon.swift → sips → iconutil → Resources/AppIcon.icns (only if missing)
            ├─ make_app Himawari.app  (+ Resources/Info.plist, AppIcon.icns)
            ├─ clang helpers/NowPlayingHelper.m → Contents/Resources/NowPlayingHelper.dylib
            ├─ make_app "Desktop Clock.app" → moved into Himawari.app/Contents/Helpers/
            └─ codesign (dylib, clock app, Himawari.app)
            ▼
 build/Himawari.app
       │                                   │
 install.sh                          scripts/make_dmg.sh (UNIVERSAL=1 ./build.sh)
   migrate settings, remove Hanabi,    stage + Read Me + Applications link
   replace /Applications/Himawari.app  → hdiutil UDRW → Finder layout → UDZO
   and open it                         → build/Himawari-<version>.dmg
```

## Package.swift

```swift
let package = Package(
    name: "Himawari",
    platforms: [.macOS("14.4")],
    targets: [
        .target(name: "HimawariKit", path: "Sources/HimawariKit"),
        .executableTarget(name: "Himawari", dependencies: ["HimawariKit"], path: "Sources/Himawari"),
        .executableTarget(name: "HimawariClock", dependencies: ["HimawariKit"], path: "Sources/HimawariClock"),
    ]
)
```
(`Package.swift:6-14`)

14 lines. The manifest's job is to compile three targets; it deliberately does not try to build
an app bundle, which SwiftPM cannot do for macOS GUI apps.

- **Tools version 5.10** (line 1). This sets the minimum toolchain and, because it is below 6.0,
  compiles every target in the Swift 5 language mode. Strict Swift 6 concurrency checking is
  therefore off; the code still annotates actors and `Sendable` by hand. The 2026-09-28
  maintenance log shows a Swift 6.3 toolchain building the package without warnings in this
  mode.
- **`.macOS("14.4")`**. The string form is needed because `SupportedPlatform.MacOSVersion` has
  no `.v14_4` case. 14.4 is not arbitrary: Core Audio process taps, which `AudioLevels` uses,
  first appeared in macOS 14.4. `LSMinimumSystemVersion` in both `Info.plist`s and the `clang
  -mmacosx-version-min` flag repeat the same number; nothing ties the four together, so a
  change has to be made in each place.
- **Targets.** `HimawariKit` is a regular library target. Without a `products:` section
  nothing is exported, and SwiftPM links the library statically into each executable that
  depends on it. That is what the app needs: each binary is self-contained, with no framework to
  embed or sign. The cost is that kit code (about 1,700 lines, including the unused Desktop
  Shell leftovers described in chapter 1) is duplicated in both executables.
- **No dependencies, no resources, no unsafe flags.** All frameworks (AppKit, AVFoundation,
  Core Audio, Carbon, WebKit, ServiceManagement, Accelerate, IOKit) are system frameworks that
  `import` links automatically. Bundle resources (the icon, the dylib, the plist) are placed by
  `build.sh`, not by SwiftPM's resource system, so `Bundle.main` works without `Bundle.module`.

The alternatives considered implicitly by this layout: an Xcode project (would give
asset catalogs, entitlements and signing in a GUI, but is harder to diff and to drive from the
maintenance bot) or a single executable with the clock in-process (which `ClockHelper.swift`'s
header comment rejects: a separate process means "a problem in one never takes down the
other").

## build.sh

81 lines of Bash. It builds `build/Himawari.app`; `install.sh` and `scripts/make_dmg.sh` both
start by calling it.

### Prologue (lines 1–6)

`set -euo pipefail` makes the script stop at the first failing command, treat unset variables
as errors and fail a pipeline if any stage fails. `cd "$(dirname "$0")"` makes all paths relative
to the repository root, so the script can be run from anywhere.

### Compiling (lines 8–17)

```bash
if [ "${UNIVERSAL:-0}" = 1 ]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN=.build/apple/Products/Release
    ARCHS=(-arch arm64 -arch x86_64)
else
    swift build -c release
    BIN=.build/release
    ARCHS=()
fi
```
(`build.sh:9-17`)

The default is a release build for the host architecture only, which is fast and is what
`install.sh` uses. With `UNIVERSAL=1`, SwiftPM is asked for two architectures. Passing more than
one `--arch` switches SwiftPM to its Xcode build-system backend, which produces fat (universal)
binaries in a different directory, `.build/apple/Products/Release`; `BIN` records which
directory to copy from. `ARCHS` holds the matching `clang` flags for the helper dylib, so the
dylib's architectures always match the executables'.

### The icon (lines 19–29)

Only if `Resources/AppIcon.icns` does not exist, the script renders the icon from code and
packs it:

1. `swift tools/make_icon.swift build/icon_1024.png` runs the drawing script as a Swift script.
2. `sips -z` (the system's "scriptable image processing system") resamples the 1024-pixel PNG
   into the ten sizes an iconset needs: 16, 32, 128, 256, 512 points, each at 1× and 2×, named
   `icon_<n>x<n>.png` and `icon_<n>x<n>@2x.png`.
3. `iconutil -c icns` packs the `.iconset` folder into `Resources/AppIcon.icns`.

Because the `.icns` is committed to git, a normal build skips this step. To change the icon you
edit `make_icon.swift` and delete the `.icns`. The intermediate files land in the ignored
`build/` directory (`build/AppIcon.iconset`, `build/icon_1024.png` are present from an earlier
run).

### The signing identity (lines 31–34)

```bash
IDENTITY="Hanabi Local Code Signing"
security find-certificate -c "$IDENTITY" >/dev/null 2>&1 || IDENTITY="-"
```

macOS's privacy system (TCC) remembers permissions such as Automation ▸ Music or System Audio
Recording against the app's *designated requirement*, which is derived from its code signature.
An ad-hoc signature (`codesign --sign -`) has no certificate, so its requirement is the exact hash
of the binary, and every rebuild looks like a new app that must be granted permissions again. A
signature from a stable certificate yields a requirement of the form "this bundle identifier,
signed by this certificate", which survives rebuilds. The script therefore uses the self-signed
identity made by `tools/make_signing_identity.sh` when the login keychain has it, and falls back
to ad-hoc signing otherwise, so a fresh checkout still builds.

`security find-certificate` checks only that a certificate with that name exists, not that its
private key is present and usable for signing. If the key were missing, the first `codesign`
call would fail and `set -e` would abort the build.

### make_app (lines 36–60)

`make_app <bundle path> <executable> <display name> <bundle id>` creates a minimal app bundle:
it deletes any old bundle, creates `Contents/MacOS` and `Contents/Resources`, copies the
executable from `$BIN`, writes an `Info.plist` from a here-document, and signs the bundle. The
generated plist contains:

| Key | Value | Meaning |
|---|---|---|
| `CFBundleName`, `CFBundleDisplayName` | the display name | name in Finder, menus, the process name in window lists |
| `CFBundleIdentifier` | the bundle id | identity for preferences, TCC, `NSRunningApplication` |
| `CFBundleExecutable` | the executable name | which file in `Contents/MacOS` to run |
| `CFBundlePackageType` | `APPL` | it is an application |
| `CFBundleShortVersionString` / `CFBundleVersion` | `1.0` / `1` | hard-coded |
| `LSMinimumSystemVersion` | `14.4` | Launch Services refuses to open it on older systems |
| `LSUIElement` | true | an agent: no Dock icon or menu bar unless the app changes its activation policy |
| `NSAudioCaptureUsageDescription` | "<name> measures how loud the song Music is playing is…" | text shown in the audio-capture prompt |
| `NSAppleEventsUsageDescription` | "<name> shows and controls what Music is playing." | text shown in the Automation prompt |

`codesign --force --sign "$IDENTITY" "$app" 2>/dev/null` replaces any existing signature
(`--force`) and hides codesign's chatter. No `--options runtime` (Hardened Runtime), no
entitlements file and no `--timestamp` are passed: none is needed for a locally built,
non-notarized app. The Hardened Runtime and a secure timestamp are what notarization would
require; without a Developer ID certificate there is no point in either.

### Assembling Himawari.app (lines 62–72)

1. `mkdir -p build`.
2. `cp Resources/Info.plist build/Himawari.Info.plist.tmp` (line 63). This copy is never read;
   line 72 deletes it. It is a leftover with no effect.
3. `make_app build/Himawari.app Himawari "Himawari" local.dhairyabhatia.himawari`.
4. Line 65 overwrites the generated plist with `Resources/Info.plist`, which has the real
   version, `CFBundleIconFile` and Himawari's own usage strings. The signature from step 3 is now
   invalid; it is redone below.
5. Line 66 copies `AppIcon.icns` into `Contents/Resources`.
6. Lines 68–69 compile the MediaRemote helper:

   ```bash
   clang -dynamiclib -fobjc-arc -O2 -mmacosx-version-min=14.4 ${ARCHS[@]+"${ARCHS[@]}"} -framework Foundation \
       helpers/NowPlayingHelper.m -o build/Himawari.app/Contents/Resources/NowPlayingHelper.dylib
   ```

   `-dynamiclib` makes a `.dylib`; `-fobjc-arc` enables automatic reference counting for the
   Objective-C code; `-O2` optimizes; the deployment target matches the app; `-framework
   Foundation` links Foundation (MediaRemote itself is opened at run time with `dlopen`, so it is
   not linked). The odd expansion `${ARCHS[@]+"${ARCHS[@]}"}` expands to the array's elements if
   the array is set and to nothing otherwise. A plain `"${ARCHS[@]}"` on an empty array is an
   "unbound variable" error under `set -u` in the Bash 3.2 that macOS ships, which would break
   the default (non-universal) build. The current `build/` copy is universal (x86_64 + arm64),
   from the last DMG build.

   The dylib must exist as a separate file because it is loaded into another program
   (`/usr/bin/perl`, see chapter 1 and `SystemNowPlaying.swift`), not into Himawari. Its exported
   entry point is `himawari_now_playing(void *interpreter, void *cv)`, the calling convention of
   a Perl XSUB in a threaded Perl.
7. Line 70 signs the dylib on its own, then line 71 re-signs the whole bundle, which now seals
   the new `Info.plist`, the icon and the already-signed dylib.

### Embedding the clock (lines 74–79)

```bash
make_app build/DesktopClock.tmp.app HimawariClock "Desktop Clock" local.dhairyabhatia.desktop.clock
mkdir -p build/Himawari.app/Contents/Helpers
rm -rf "build/Himawari.app/Contents/Helpers/Desktop Clock.app"
mv build/DesktopClock.tmp.app "build/Himawari.app/Contents/Helpers/Desktop Clock.app"
codesign --force --sign "$IDENTITY" build/Himawari.app
```
(`build.sh:75-79`)

The clock is built as a complete, signed app at a temporary path and then moved into
`Contents/Helpers`, the conventional place for helper apps inside a bundle. A code signature does
not include the bundle's own path, so moving it keeps the signature valid. Its bundle id and
display name ("Desktop Clock") are what macOS shows in Activity Monitor and in window lists, and
the id `local.dhairyabhatia.desktop.clock` is the one `ClockHelper.retireOldService` looks for when
removing the old launchd copy. Finally the outer app is signed a third time so its seal covers the
nested app. Signing inside-out like this is what `codesign --deep` would do automatically; doing
it explicitly is the approach Apple recommends.

`ClockHelper.executable` (`ClockHelper.swift:14-17`) expects exactly
`Contents/Helpers/Desktop Clock.app/Contents/MacOS/HimawariClock`; if this part of the build were
skipped, Himawari logs "clock: not included in this build" and runs without a clock.

The clock's plist is the generic one from `make_app`: version 1.0 (1) regardless of the app's
version, no icon, and an audio-capture usage string the clock never needs.

### Notes and risks

- `build.sh:63,72`: the `Himawari.Info.plist.tmp` copy is dead.
- `build.sh:51-52`: the helper app's version is hard-coded to 1.0 (1) and does not follow
  `Resources/Info.plist`.
- `build.sh:59`: `2>/dev/null` hides codesign's error text; with `set -e` a failure still stops the
  build, but without saying why.
- `build.sh:68-69`: a dylib in `Contents/Resources` is code in a location Apple's bundle
  guidelines reserve for resources. Signed separately it works; tools that validate bundle
  structure strictly (notarization, `codesign --verify --strict`) may object.
- `build.sh:20`: icon regeneration is triggered only by the `.icns` being absent, so editing
  `make_icon.swift` alone changes nothing.
- The build does not run any tests (there are none in the package).

## tools/make_icon.swift

96 lines; a Swift *script* (top-level code, run with `swift tools/make_icon.swift out.png`), not
part of any target. It draws the icon into a 1024×1024 `NSBitmapImageRep` through Core Graphics
and writes a PNG.

| Lines | What is drawn |
|---|---|
| 5–12 | Canvas: an RGBA bitmap rep made the current graphics context; a device-RGB colour space; `rgb(_:_:_:_:)` helper taking 0–255 components. |
| 14–22 | The macOS icon grid: an 824×824 body with a 100-pixel margin and 186-pixel corner radius, filled blue with a soft drop shadow (offset −14, blur 28). |
| 24–33 | Clipped to the body: a vertical sky gradient (deep blue → mid blue → pale blue at the horizon) and a warm radial sun-glow behind the flower (radius 430). |
| 37–63 | `petal(angle:length:width:base:colors:)`: a petal path made of two quadratic curves, rotated around the centre (512, 530), clipped and filled with a linear gradient. Two rings of 18 petals: a back ring, deeper orange, offset by half a petal; a front ring, brighter yellow. Both under a brown shadow. |
| 65–84 | The seed disc (radius 150): a radial brown gradient, then 260 seeds placed on the golden-angle spiral (`π(3 − √5)`), radius growing with √n, size growing outward, every third seed lighter — the arrangement real sunflower heads grow in. |
| 86–92 | A white gloss gradient over the top of the tile and a thin light stroke around its edge. |
| 94–96 | Releases the context and writes the PNG to the argument (default `icon.png`), with `try!`. |

The same motif, simplified to twelve petals and a disc, is drawn at 18×18 for the menu-bar
template icon in `AppDelegate.sunflowerIcon` (chapter 3). Drawing in code keeps the repository
free of design-tool files and makes the icon reproducible.

## tools/make_signing_identity.sh

26 lines; run once by hand. It creates the identity `build.sh` looks for.

1. `set -euo pipefail`; `NAME="Hanabi Local Code Signing"` (the app's former name).
2. If `security find-certificate -c "$NAME"` finds it, print "Already exists" and stop
   (idempotent).
3. Make a temporary directory, removed on exit by a `trap`.
4. Write an OpenSSL config: subject CN = the name; extensions `keyUsage = critical,
   digitalSignature`, `extendedKeyUsage = critical, codeSigning`, `basicConstraints = critical,
   CA:false`. The code-signing extended key usage is what makes `codesign` accept the certificate
   as a signing identity.
5. `/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650` creates a self-signed
   certificate and an unencrypted RSA key, valid ten years.
6. `/usr/bin/openssl pkcs12 -export … -passout pass:himawari` bundles key and certificate into
   a PKCS#12 file. The path is pinned to `/usr/bin/openssl` (Apple's LibreSSL); a Homebrew
   OpenSSL 3 earlier in `PATH` would produce a PKCS#12 encryption that `security import` cannot
   read without `-legacy`.
7. `security import … -k ~/Library/Keychains/login.keychain-db -P himawari -T /usr/bin/codesign`
   imports it into the login keychain and adds `codesign` to the key's access list, so builds do
   not trigger a keychain password prompt.

The password `himawari` only protects the temporary `.p12`, which is deleted. The certificate is
not trusted by any root, so signatures made with it do not pass Gatekeeper on other Macs (the
DMG's Read Me explains how to open the app anyway); locally it is used only for the stable
designated requirement described above. The comment correctly notes it can be deleted in
Keychain Access at any time.

## helpers/NowPlayingHelper.m (as a build input)

The helper's behaviour is described in chapter 1; from the build's point of view it is one
97-line Objective-C file compiled straight to a dylib with no headers of its own (it includes only
Foundation, `math.h` for `isfinite` and `dlfcn.h`). It resolves all
MediaRemote symbols with `dlsym` (`MRMediaRemoteRegisterForNowPlayingNotifications`,
`MRMediaRemoteGetNowPlayingInfo`, `MRMediaRemoteGetNowPlayingApplicationPID`, and the three
notification-name constants), so it neither links against nor needs headers for the private
framework, and a missing symbol becomes a clean `exit(1)` that `SystemNowPlaying` treats as a
failed start. Before printing, it drops any non-finite number (MediaRemote can report NaN,
which `NSJSONSerialization` cannot encode and would raise on) and skips the message if
`isValidJSONObject` still fails. At run time `SystemNowPlaying.start` removes the `com.apple.quarantine` extended
attribute from the dylib, because a copy downloaded inside the DMG is quarantined and Perl will
not load a quarantined library.

## Resources/Info.plist

30 lines; Himawari's real `Info.plist`, copied over the generated one by `build.sh:65`.

| Key | Value | Notes |
|---|---|---|
| `CFBundleDisplayName`, `CFBundleName` | Himawari | |
| `CFBundleExecutable` | Himawari | must match the SwiftPM product name |
| `CFBundleIconFile` | AppIcon | resolves to `Contents/Resources/AppIcon.icns` |
| `CFBundleIdentifier` | `local.dhairyabhatia.himawari` | also the `UserDefaults.standard` domain; a reverse-DNS name under `local.` because there is no registered domain or team |
| `CFBundlePackageType` | APPL | |
| `CFBundleShortVersionString` | 1.1.3 | the marketing version; `make_dmg.sh` names the DMG after it |
| `CFBundleVersion` | 5 | build number, incremented by hand per release |
| `LSMinimumSystemVersion` | 14.4 | |
| `LSUIElement` | true | starts as an agent; `AppDelegate.applyDockVisibility` switches to `.regular` when "Show in Dock" is on |
| `NSAppleEventsUsageDescription` | "…reads what Music is playing … and checks Finder's selection when you click the desktop." | shown in both Automation prompts (Music, Finder); required, or Apple events to other apps fail without a prompt |
| `NSAudioCaptureUsageDescription` | "…measures how loud the song Music is playing is… Nothing is recorded." | shown in the "System Audio Recording Only" prompt that `AudioPermission.request` triggers |

There is no `NSPrincipalClass` (the app sets up `NSApplication` itself in `main.swift`) and no
`NSHighResolutionCapable` (it is the default for modern bundles).

## install.sh

49 lines. Builds and installs to `/Applications`, migrating old state on the way.

1. **Build** (line 7): `./build.sh`, so the install is always of fresh code.
2. **Settings split** (lines 9–26). If `local.dhairyabhatia.desktop` has no `migrated` key, an
   embedded Python 3 script exports Himawari's preferences with `defaults export … -`, and for a
   list of keys that used to live there (`showClock`, `clockPosition`, `clock24h`,
   `clockSeconds`, and Desktop Shell's `showWidgets`, `widgetsCollapsed`, `widgetEdge`,
   `showFolders`, `foldersIncludeDownloads`, `keepWindowsClear`) writes each into the shared
   domain with `defaults write`, as `-bool` if the value is a Python `bool` and `-string`
   otherwise. It then deletes those keys, plus any `zone.*` / `dockBackup.*` keys and
   `widgetsTopRight`, from Himawari's domain, and sets `migrated = true`. The `-string`
   fallback would turn any numeric value into a string; for the listed keys (booleans and
   enum raw values) that is harmless.
3. **Rename from Hanabi** (lines 28–38). If `/Applications/Hanabi.app` exists: ask it to quit by
   AppleScript (`tell application id "local.dhairyabhatia.hanabi" to quit`), wait 2 s, `pkill`
   anything still running from that path, and delete it. If Himawari has no preferences yet but
   Hanabi does, `defaults export local.dhairyabhatia.hanabi - | defaults import
   local.dhairyabhatia.himawari -` carries them over.
4. **Replace the app** (lines 40–47). If Himawari is running from `/Applications`, quit it the
   same way (AppleScript, 2 s, `pkill`); delete `/Applications/Himawari.app`; `cp -R` the new
   build; `open` it. Quitting first matters because `applicationWillTerminate` stops the clock
   helper; a `pkill` (SIGTERM) does not run that delegate method, but the clock's parent-pid
   watchdog stops it within about 3 s anyway.

Every AppleScript and `pkill` is followed by `|| true` where failure is expected, so `set -e`
does not abort an install when nothing was running.

### Notes and risks

- `install.sh:11`: relies on `python3`, which macOS provides only with the Command Line Tools
  (already required to build, so in practice present).
- `install.sh:20`: non-boolean values are migrated as strings.
- `install.sh:45-46`: there is no backup of the installed app; a broken build replaces a working
  one (the weekly bot only installs after a successful build, but a build can succeed and the
  app still misbehave).
- `install.sh:41-43`: the fixed 2-second wait can be too short if Himawari is busy (for example
  during an Aerial conversion); `pkill` then interrupts it.

## scripts/make_dmg.sh

81 lines. Makes the shareable disk image.

1. **Universal build** (line 12): `UNIVERSAL=1 ./build.sh`.
2. **Version** (line 13): `PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist`
   gives e.g. `1.1.3`; the image is `build/Himawari-$VERSION.dmg`.
3. **Stage** (lines 14–19): clear `build/dmg`, the target DMG and any left-over read-write image;
   copy the app; create a symbolic link `Applications → /Applications` for drag-to-install.
4. **Read Me** (lines 20–54): a here-document written to `Read Me First.txt` with install steps
   (including the right-click ▸ Open / "Open Anyway" route for a non-notarized app), a summary of
   the menu, the three permission prompts, the clock and its ⌃⌥⌘C shortcut, and uninstalling. The
   `$VERSION` variable is substituted.
5. **Writable image** (lines 56–58): `hdiutil create -format UDRW` from the staging folder, then
   `hdiutil attach -readwrite -noverify -noautoopen`; the mount point is cut from `hdiutil`'s
   tab-separated output with `awk -F'\t' '/\/Volumes\// {print $NF}'`.
6. **Window layout** (lines 59–76): an AppleScript to Finder opens the mounted disk "Himawari",
   sets icon view without toolbar or status bar, a 560×360 window, 112-point icons, and places
   the app at (140, 150), Applications at (420, 150) and the Read Me at (280, 290). Finder saves
   this in the volume's `.DS_Store`, which is why the image must be writable at this stage. If
   the script cannot control Finder (no Automation permission for the terminal), it prints
   "(window layout skipped)" and continues.
7. **Finish** (lines 77–81): `sync`; detach; `hdiutil convert -format UDZO -imagekey
   zlib-level=9` makes the compressed read-only image; delete the writable one; print the path
   and size.

The staging folder `build/dmg` is left in place after the run (it is ignored by git).

### Notes and risks

- `scripts/make_dmg.sh:61`: Finder addresses the volume by name; if another volume called
  "Himawari" is mounted (an older DMG left open), the layout is applied to the wrong one.
- The DMG and the app inside it are not notarized, and the DMG itself is not signed; Gatekeeper
  warns on first open, as the Read Me explains.
- The version comes only from `Resources/Info.plist`; nothing checks that a matching git tag
  exists or that the README's download links (which hard-code the file name) were updated.

## maintenance/weekly.sh and maintenance/prompt.md

### What schedules it

`weekly.sh` is run by a user launch agent that lives outside the repository, at
`~/Library/LaunchAgents/local.dhairyabhatia.hanabi-maintenance.plist`. That plist runs
`/bin/bash ~/hanabi-mac/maintenance/weekly.sh` with `StartCalendarInterval` weekday 1, hour 14,
minute 0 (Monday 14:00; launchd runs a missed calendar job at the next wake), sends stdout and
stderr to `maintenance/logs/launchd.log`, and sets `Nice 10` and `LowPriorityIO` so the job
yields to interactive work. The plist is not version-controlled; the README documents how to turn
it off with `launchctl bootout`.

### weekly.sh, step by step

83 lines; `set -uo pipefail` (deliberately without `-e`: individual steps may fail).

| Lines | Step |
|---|---|
| 18 | A fixed `PATH` including `~/.local/bin` (where `claude` lives) and both Homebrew prefixes, because launchd starts jobs with a minimal environment. |
| 20–24 | `REPO=~/hanabi-mac`; all output appended to `maintenance/logs/<date>.log` via `exec >>"$LOG" 2>&1`; `cd` into the repo or exit. |
| 26 | `notify()` posts a macOS notification with `osascript … display notification`. |
| 29–34 | Records `BEFORE=$(git rev-parse HEAD)`. If `git status --porcelain` shows anything (modified *or untracked* files), logs and notifies "Skipped" and exits 0, so the bot never mixes its changes with the user's work in progress. |
| 36–46 | Unless `--dry-run`: `brew update && brew upgrade && brew upgrade --cask --greedy ghostty && brew cleanup -s`, then `rustup update stable`. Failures only change the `DEPS` summary text. |
| 48–57 | Unless `--dry-run`: runs Claude Code headless with the prompt file. |
| 59–66 | `./build.sh`. On failure: `git reset --hard "$BEFORE"`, `git clean -fdq -e maintenance/logs`, rebuild the old code, notify, exit 1. |
| 68–72 | If the build passed and the tree is clean, notify "All good" and exit. |
| 74–77 | Otherwise `git add -A` and commit as "Himawari maintenance bot" with the user's address, message "Weekly maintenance <date>". |
| 82–83 | `./install.sh` (quits, replaces and reopens the installed app), then notify with the commit subject. |

The Claude invocation (lines 50–55):

```bash
claude -p "$(cat maintenance/prompt.md)" \
    --model claude-opus-5 \
    --permission-mode dontAsk \
    --allowedTools "Read Glob Grep Edit Write Bash(swift build:*) Bash(swift --version) Bash(sw_vers:*) Bash(git diff:*) Bash(git status:*) Bash(git log:*)" \
    --max-budget-usd 2 \
    --no-session-persistence
```

`-p` is non-interactive "print" mode. `--permission-mode dontAsk` means any tool not on the
allow-list is refused rather than prompted for (nobody is there to answer). The allow-list gives
file reading and editing, `swift build` with any arguments, and read-only git and version
commands — no `git commit`, no network tools, no `rm`. The spend is capped at 2 USD per run and
the session is not saved. The 2026-09-28 log shows the effect: the agent could not delete its own
scratch build directories because `rm` was not allowed, and said so.

### prompt.md

24 lines. It tells the agent what the project is, that dependencies are already updated, and to:
check `sw_vers` and `swift --version`; build in release; fix only what is broken or newly
deprecated because macOS or the toolchain changed (errors, warnings, deprecations, concurrency
diagnostics), minimally and in the surrounding style; rebuild until clean; update `README.md` if
behaviour changes. Rules: no features, redesigns or refactors ("Nothing to do" is a good outcome),
nothing outside the directory, do not run or install the app (the wrapper does that and rolls
back failures), finish with a short plain-text summary, which lands in the log.

The design puts trust in the wrapper, not the agent: whatever the agent says, the script verifies
with a clean `./build.sh` and owns committing, installing and rolling back.

### Notes and risks

- `maintenance/weekly.sh:30`: `git status --porcelain` counts untracked files, so the untracked
  `docs/report/` chapters make every run skip until they are committed or ignored.
- `maintenance/weekly.sh:41`: `brew upgrade` upgrades every Homebrew package on the Mac, a
  machine-wide side effect unrelated to Himawari; the Ghostty and Rust steps are Desktop Shell
  leftovers. The 2026-09-28 log shows both failing ("Cask 'ghostty' is not installed",
  "rustup: command not found").
- `maintenance/weekly.sh:79-81`: the comment says the apps are ad-hoc signed, so permissions are
  re-asked after each update; `build.sh` uses the stable local identity when present, so the
  comment is out of date.
- `maintenance/weekly.sh:62`: `git reset --hard` is safe only because of the dirty-tree check at
  the top; the `-e maintenance/logs` exclusion is redundant (ignored paths are not removed
  without `-x`).
- `maintenance/weekly.sh:82`: an unattended install quits and relaunches the running app, which
  interrupts any Moving Lock Screen conversion in progress (since 1.1.3 it restarts on launch).
- `maintenance/weekly.sh:51`: the model id is pinned in the script; if that id is retired, the
  Claude step fails, the build still runs, and the notification still reports success with no
  changes.

## .gitignore

```
.build/
build/
maintenance/logs/
.DS_Store
```

SwiftPM's build directory, the assembled apps and DMGs, the bot's logs (which contain dependency
lists and agent output), and Finder metadata. Release DMGs are therefore never committed; they are
uploaded to GitHub Releases. `Resources/AppIcon.icns` and the `docs/` images are committed.

## Versioning and releases

- **Version numbers** live only in `Resources/Info.plist`: `CFBundleShortVersionString` (1.0, 1.1,
  1.1.1, 1.1.2, 1.1.3) and `CFBundleVersion`, a build counter that is 5 at 1.1.3. The clock helper's
  numbers stay at 1.0 (1).
- **Tags.** `v1.0` (983092c), `v1.1` (4e55f5c), `v1.1.1` (39575e0), `v1.1.2` (473992f) and `v1.1.3`
  (cbebb05). The README states that history is collapsed to one commit per release, and the log
  shows exactly that, with one exception: a "Beta 1.2" commit (17fb651) was followed by "Version
  1.1.2 (not 1.2)" (473992f) that renamed it; `build/` still holds the `Himawari-1.2.dmg` built in
  between. After `v1.1.3` the history continues with ordinary fix commits (782c03a, 22c0feb) that
  are not yet part of a release.
- **Release steps** are manual and unscripted: edit the two version keys, run
  `scripts/make_dmg.sh`, update the hard-coded DMG file name in the README's download links,
  commit, tag, and upload the DMG. The README links to
  `github.com/dhairyab0069/himawari-mac/releases/latest/download/Himawari-<version>.dmg` and to a
  separate project page and release list in the `himawari-io` repository.
- **Signing for release** uses the same local self-signed identity as development builds (on
  the machine that has it), so users see the unidentified-developer warning; notarization would
  need a paid Developer ID.
- **ROADMAP.md** records what each beta added (interactive gear and CD, BASS / TREBLE and REPEAT /
  SHUFFLE in 1.1, "just the wallpaper" in 1.1.2) and has no queued ideas.

### Notes and risks

- Version numbers, minimum OS and download links are repeated by hand across `Info.plist`,
  `build.sh`, `Package.swift` and `README.md`, with no check that they agree.
- Collapsing history to one commit per release makes `git bisect` within a release impossible.
