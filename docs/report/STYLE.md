# Code report: style for chapter authors

You are writing one chapter of "Himawari: the code, explained", a book-length technical report
(target: 50+ printed pages in total) that explains every file, type and function of ~/hanabi-mac.

- Write Markdown to the file you're given. Start with `# N · Chapter title`. Use `##` for each
  source file (`## Sources/Himawari/WallpaperManager.swift`), `###` for each type or group of
  functions, and `####` sparingly.
- For **every file**: what it is for, where it sits in the app, who calls it and what it calls,
  its line count, and the design decisions behind it (why it's built this way, the alternatives).
- For **every type**: its responsibility, its stored state (a table: property · type · meaning),
  its lifecycle (who creates it, when it goes away), and its threading (MainActor, audio thread, queues).
- For **every function / method / computed property** (including private ones): what it does,
  its inputs and outputs, the steps it takes, side effects, edge cases it handles, and anything
  subtle (races, retain cycles avoided, units, coordinate systems). Short functions can share a
  paragraph or a table row; important ones get their own subsection with a short code excerpt
  (≤ 15 lines, quoted exactly, with `file:line`).
- Explain the platform APIs used (AVFoundation, Core Animation, Core Audio, AppKit window levels,
  AppleScript, MediaRemote, TCC, launchd…) as you go, for a reader who knows Swift but not these.
- Add at least one small ASCII diagram or table of the data flow / state machine where it helps.
- Note any bug, smell or risk you see in a final `### Notes and risks` subsection per file
  (factual, with file:line). Don't edit any source file.
- Accuracy over flourish: read the code; never describe behaviour you haven't seen in it.
- Plain, precise English. No marketing tone.
