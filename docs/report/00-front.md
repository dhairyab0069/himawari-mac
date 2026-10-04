---
title: "Himawari: the code, explained"
subtitle: "A file-by-file technical report on the live music wallpaper for macOS"
author: "Dhairya Bhatia"
date: "Beta 1.1.4 · 4 October 2026"
---

# About this report

This report explains every part of Himawari's source code, as of Beta 1.1.4: every file, type and
function, the macOS frameworks they use, and the reasons behind the design. Each chapter covers one
area and ends each file with *Notes and risks*: things a maintainer should know. The last chapter is
a health report on this release: how the code was checked, what was found and fixed, how it performs,
and what remains open.

| Chapter | Covers |
|---|---|
| 1 · What Himawari is and how it's put together | the product, processes, targets, file map, data flows, threading, persistence |
| 2 · Building, packaging and maintaining it | Package.swift, build and install scripts, the DMG, signing, the weekly bot |
| 3 · Start-up, menus and settings | main.swift, AppDelegate, both Settings types, logging, the main-thread helper |
| 4 · The wallpaper engine | WallpaperManager, VideoCanvas, AmbientFill, PlaybackMonitor, DesktopPeek, power and windows |
| 5 · Knowing what's playing | MusicNowPlaying, SystemNowPlaying, the Now Playing helper, artwork and motion-cover search |
| 6 · The CD scene | MusicScene and DiscPrint |
| 7 · The side gear, its controls and the audio meters | NowPlayingSides, GearControls, AudioLevels, AudioPermission |
| 8 · The desktop clock and its contrast | the clock helper app, ClockHelper, ToneReporter, WallpaperTone, hotkeys, Aero style |
| 9 · The lock screen | LockScreen and MovingLockScreen |
| 10 · Health report | checks, findings and fixes, performance, open issues |

Line numbers (`file:line`) refer to the code as each chapter was written (between Betas 1.1.3 and 1.1.4), so after later fixes they can be a few lines off; the source is at
<https://github.com/dhairyab0069/himawari-mac>. The code, and this report, were written with
AI assistance (Claude Code); the report's chapters were drafted by reading the code itself, and
each finding was checked against it.
