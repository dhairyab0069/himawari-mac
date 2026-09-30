<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Hanabi app icon: a golden firework on a night-blue tile">
</p>

<h1 align="center">Hanabi</h1>

<p align="center">
  A live video wallpaper for macOS that turns into your music: Apple Music's animated album art,<br>
  retro hi-fi gear that follows the song, and a spinning CD for everything else.
</p>

<p align="center">
  <a href="https://github.com/dhairyab0069/hanabi-mac/releases/latest/download/Hanabi-1.0.dmg"><b>⬇︎ Download Hanabi 1.0 (DMG)</b></a>
  &nbsp;·&nbsp; macOS 14.4 or later &nbsp;·&nbsp; Apple Silicon and Intel
</p>

---

## Contents

- [Features](#features)
- [Install](#install)
- [Using Hanabi](#using-hanabi)
  - [Your wallpaper](#your-wallpaper)
  - [The music wallpaper](#the-music-wallpaper)
  - [Hide the desktop's files](#hide-the-desktops-files)
- [The Desktop Shell (optional)](#the-desktop-shell-optional)
- [Permissions](#permissions)
- [Battery](#battery)
- [How it works](#how-it-works)
- [Building from source](#building-from-source)
- [Project layout](#project-layout)
- [Weekly maintenance bot](#weekly-maintenance-bot)
- [Roadmap](#roadmap)

## Features

| | |
|---|---|
| **Live wallpaper** | Any `.mp4` / `.mov` as your wallpaper, filling the screen. Pauses when covered, locked, asleep or on battery. |
| **Apple Music artwork** | While a song plays, the album's animated cover becomes the wallpaper, shown whole, never cropped. |
| **Retro hi-fi side gear** | Beside the artwork: a CD deck (fluorescent display, time, progress, transport, jog wheel) and a stereo analyzer whose VU needles and spectrum follow the actual music. |
| **Spinning CD** | Songs without an animation get their cover wrapped onto a spinning CD, with a disc-changer transition between songs and little characters running along the bottom. |
| **Click to hide files** | Click an empty spot on the desktop to see just the wallpaper; click again to bring the files back. |
| **Desktop Shell** | Optional background services: XP taskbar and Start menu, iOS-style desktop folders, an interactive desktop clock, widgets, global hotkeys. |

## Install

1. [Download the DMG](https://github.com/dhairyab0069/hanabi-mac/releases/latest/download/Hanabi-1.0.dmg) and open it.
2. Drag **Hanabi** onto **Applications**, then open it from Applications.
3. The first time, macOS may say it can't check Hanabi for malicious software: Hanabi isn't notarized
   (that needs a paid Apple Developer ID). Either right-click Hanabi ▸ **Open** ▸ **Open**, or go to
   **System Settings ▸ Privacy & Security** and click **Open Anyway**.

Hanabi lives in the menu bar (the firework icon). To uninstall, remove the Desktop Shell first if you
installed it (see below), quit Hanabi, and move it to the Trash.

> **Note:** the repository is private for now, so the download link works for you and any
> collaborators you add. It becomes public if the repository does.

## Using Hanabi

Everything is in the menu-bar icon's menu.

### Your wallpaper

| Menu item | What it does |
|---|---|
| **Choose Video…** | Picks the wallpaper video. It always fills the whole screen. |
| **Pause / Resume**, **Mute**, **Volume** | Playback controls. Wallpapers are muted by default. |
| **Pause When Desktop Is Covered** | Stops decoding video nobody can see. |
| **Pause on Battery** | Pauses the wallpaper on battery power. |
| **Show in Dock**, **Launch at Login** | Where and when Hanabi appears. |

Hanabi never keeps your Mac awake. `.webm` files won't play; convert them with
`ffmpeg -i in.webm -c:v h264_videotoolbox -b:v 8M -an out.mp4`.

### The music wallpaper

Turn on **Use Apple Music Artwork While Playing**. While a song plays in Music:

- **Albums with an animated cover:** the animation becomes the wallpaper, shown whole and kept below
  the notch, streamed at the sharpest size your screen can show (up to 2160×2160). The bars at its
  sides become **retro hi-fi gear in a rack**:
  - *CD deck* (left): a cyan fluorescent display with PLAY / PAUSE, elapsed and remaining time, a
    segmented progress ladder, and the song, artist and album (long titles scroll); a disc tray,
    transport buttons, and a jog wheel that turns while playing.
  - *Stereo analyzer* (right): two amber-lit analog VU meters and a 10-band spectrum display that move
    with the actual music, plus bass, treble and volume knobs.
- **Albums without one:** the cover is wrapped onto a **spinning CD**, like a printed picture disc, with a
  see-through center hole, a silver ring and a soft rainbow luster. The same side gear sits beside it.
  Changing songs works like a disc changer: the old CD slides out, the new one slides in and spins up.
- **…or a YouTube Loop of the Song** (off by default): instead of the CD, the song's music video from
  YouTube's embedded player, kept in step with the song.
- **Pausing** the song brings your own wallpaper back.

**Music Video Sizing ▸** sets how the music wallpaper fits: *Widescreen* (the default: whole video, bars
where needed), *Show Whole Video*, *Fit Width*, *Fill Screen*, and **Fill Gaps With ▸** *Soft Colors*
(a slow glow in the video's own edge colors, the default), *Blurred Video* or *Black Bars*.

### Hide the desktop's files

With **Click Desktop to Hide Files** on (the default), click an empty spot on the desktop: the files
and folders disappear and it's just the wallpaper. Click the wallpaper again to bring them back. Clicks
on files, selection rectangles and double-clicks work as usual.

## The Desktop Shell (optional)

Five background services that restyle the desktop. They run on their own (started at login by
`launchd`, restarted if they crash), have no Dock or menu-bar icons, and don't depend on Hanabi.

**Install** from **Hanabi menu ▸ Desktop Shell ▸ Install…**, and remove it the same way. Your Dock and
Finder's desktop icons come back when it's removed. Settings live in **Start ▸ Desktop Settings**.

| Service | What it does |
|---|---|
| **XP Taskbar** | A Windows XP taskbar in place of the Dock, hidden in full-screen apps (push the pointer against the bottom edge to reveal it). **Start** (the Apple logo, or tap **⌥ Option**) opens an XP Start menu with pinned and frequent apps, All Programs, search (apps instantly, files via Spotlight), recent documents, your folders, Desktop Settings and Turn Off Computer, fully keyboard-driven. One button per open app, an XP-style **Downloads** window, a tray clock. Also a **window tiler** that keeps app windows out of the taskbar, widget and folder strips. |
| **Desktop Folders** | Every folder on your Desktop as an iOS-style folder (loose files grouped by type). Drag tiles to rearrange; click to zoom open. |
| **Desktop Clock** | A big see-through clock. **Left-click** cycles 12-hour → 24-hour → Swatch Internet Time (.beats) → French decimal time → in words ("quarter past six"). **Right-click** for format, seconds, date, size, style (Aero glass, fluorescent display, rounded, serif), position, or Hide. It ticks exactly with the system clock, and its text adapts to whatever is behind it. |
| **Desktop Widgets** | An Aero panel: Now Playing (with the album's animation), calendar, battery, CPU and memory, storage. Dock it to any edge. |
| **Desktop Hotkeys** | **⌘⌃T** opens a Ghostty terminal on the current Space (the Quick Terminal over full-screen apps); **tap ⌥ Option** for Start. |

From a source checkout you can also control each service with `desktopctl`:

```bash
desktopctl status              # what's running
desktopctl stop    taskbar     # stop now (starts again at next login)
desktopctl start   taskbar
desktopctl restart all
desktopctl disable clock       # stop, and don't start at login
desktopctl enable  clock
```

## Permissions

macOS asks once for each of these, the first time it's needed.

| App | Permission | Why |
|---|---|---|
| Hanabi | **Automation ▸ Music** | Reads what's playing and the album cover. |
| Hanabi | **Automation ▸ Finder** | Checks whether a desktop click landed on a file (click to hide files). |
| Hanabi | **System Audio Recording Only** | Measures the music's loudness for the VU meters. Nothing is recorded; decline and the meters animate on their own. |
| Desktop Folders | **Desktop folder** | Shows your folders. |
| XP Taskbar | **Accessibility**, **Downloads folder** | The window tiler and Start search; the Downloads window. |
| Desktop Hotkeys | **Accessibility** | Notices a tap of ⌥ Option anywhere; opens Ghostty's Quick Terminal over full-screen apps. |

Missed a prompt? Turn it on in **System Settings ▸ Privacy & Security**, then quit and reopen the app.

## Battery

Battery Saver turns on by itself on battery or in Low Power Mode:

- The wallpaper pauses while windows cover most of the screen, and music artwork streams at 1080p.
- YouTube loops and the blurred fill are skipped; the side gear's motion, the CD's runners and the
  luster's drift rest.
- Widgets and folder tiles drop live blur; background checks run half as often.

Always, regardless of power: a muted wallpaper never decodes its audio; the side gear and its audio
measuring run only while you can see the desktop and a song is playing; animations run at low frame
rates in the window server. Hanabi idles at well under 1% CPU.

## How it works

- **Song timing** comes from the system's Now Playing state (what Control Center shows), pushed the
  instant you play, pause, seek or skip, within about 0.05 s of Music. macOS lets only Apple's own
  programs read it, so a tiny bundled helper (`helpers/NowPlayingHelper.m`) runs inside Apple's
  `/usr/bin/perl`, which may. This is unofficial: if a macOS update closes that door, Hanabi falls
  back to asking Music over AppleScript.
- **Motion artwork:** Apple's public iTunes Search API finds the album, and its public Apple Music
  page lists the looping video. That page isn't an official API, so if Apple changes it you get the CD.
- **VU meters and spectrum:** a Core Audio process tap on Music, measured (never saved) with an FFT.
- **The CD print:** the cover is projected onto the disc in log-polar form, a rosette of mirrored
  copies that keeps the art's proportions so text stays readable. It's made on all cores in about
  10 ms, once per cover.
- **Clock contrast:** the desktop clock tells Hanabi where it sits; Hanabi measures exactly what's
  behind it (video, bars, CD, or a YouTube thumbnail) and answers, again whenever that changes.
- **YouTube** plays in YouTube's own embedded player; nothing is downloaded.

## Building from source

Requires Xcode (Swift 5.10 or later) on macOS 14.4 or later.

```bash
./install.sh                    # build, then install/update Hanabi and the Desktop Shell
./install.sh --uninstall-shell  # remove the Desktop Shell services
scripts/make_dmg.sh             # build the shareable DMG → build/Hanabi-<version>.dmg (universal)
```

Builds are signed with a local identity (`tools/make_signing_identity.sh`) so the permissions you
grant survive rebuilds. `install.sh` never turns back on a service you disabled.

Logs: `~/Library/Logs/Hanabi.log` and `~/Library/Logs/Desktop Shell/<service>.log`.

## Project layout

| Path | Contents |
|---|---|
| `Sources/Hanabi/` | The wallpaper app. `WallpaperManager` (what's on the wallpaper, and when), `VideoCanvas` (one screen's video and its bars), `MusicScene` + `DiscPrint` (the CD), `NowPlayingSides` (the side gear), `AudioLevels` (the audio tap), `ToneReporter` (clock contrast), `DesktopPeek` (click to hide files), `PlaybackMonitor` (pause rules), `AppDelegate` (menus), `Settings`, `Log`. |
| `Sources/HanabiKit/` | Shared code: `Settings` (one preferences domain plus a change broadcast), `NowPlaying` + `SystemNowPlaying` (Apple Music), `WallpaperTone` (brightness readings), `DesktopLayout` (the tiling map), `DesktopWindow` (desktop-level windows), `PowerState`, `AeroStyle`. |
| `Sources/HanabiTaskbar/`, `HanabiFolders/`, `HanabiClock/`, `HanabiWidgets/`, `HanabiHotkeys/` | The Desktop Shell services. |
| `helpers/NowPlayingHelper.m` | The system Now Playing stream. |
| `scripts/` | `shell.sh` (installs / removes the services), `make_dmg.sh`. |
| `tools/` | The app icon and the signing identity. |
| `maintenance/` | The weekly bot. |

Window layers, counted up from the system wallpaper: video +1, Finder's icons +20, clock, folders and
widgets +22, an open folder +23; app windows above those; the taskbar at the Dock's level.

## Weekly maintenance bot

Every **Monday at 2 PM** (or at the next wake), `launchd` runs `maintenance/weekly.sh`:

1. Skips the run if there are uncommitted changes.
2. Updates Homebrew and everything it installed (including Ghostty), and the Rust toolchain.
3. Claude Code fixes only what a new macOS or Swift broke (`maintenance/prompt.md`), capped at $2.
4. Rebuilds. If the build passes and code changed, it commits and runs `./install.sh`; if it fails,
   it rolls everything back.
5. Sends a notification. Logs go to `maintenance/logs/`.

| To | Run |
|---|---|
| Run it now | `maintenance/weekly.sh` |
| Test without Claude or updates | `maintenance/weekly.sh --dry-run` |
| See what it changed | `git log -p` |
| Undo its last change | `git revert HEAD && ./install.sh` |
| Turn it off | `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/local.dhairyabhatia.hanabi-maintenance.plist` |

## Roadmap

See [ROADMAP.md](ROADMAP.md): interactive side panels, and a CD you can grab and spin to scrub
through the song.

---

<p align="center"><sub>Inspired by <a href="https://github.com/jeffshee/gnome-ext-hanabi">Hanabi for GNOME</a>.</sub></p>
