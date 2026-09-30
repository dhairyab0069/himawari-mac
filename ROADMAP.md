# Roadmap

Ideas to build later.

1. **Interactive side panels.** The retro hi-fi gear beside the music wallpaper
   (`Sources/Hanabi/NowPlayingSides.swift`) responds to clicks: the transport buttons
   play / pause / skip in Music, the jog wheel and progress ladder seek, the knobs do
   something useful (volume, for one).
2. **Interactive CD.** In the CD scene (`Sources/Hanabi/MusicScene.swift`), grab and spin
   the disc to scrub forward or back through the song, with a sound of the disc moving.

Both need the wallpaper to receive clicks where the gear or the disc is, while the rest of
the desktop stays click-through (the wallpaper window currently sits below Finder's icons
and ignores the mouse, except in "click the desktop to hide files" mode).
