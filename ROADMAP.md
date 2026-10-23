# Roadmap

What comes after the Beta 1.1 series. Betas 1.2 to 1.5 are the **last of Beta 1** (all out); the
listening work is **Beta 2**, which I'm building myself, hands-on, as part of learning machine
learning. Alongside it, **Himawari goes beyond the Mac**: a shared core, **Linux** (Debian and
Ubuntu), a link between your computer and your TV, and **Fire TV**, each starting as its own beta.
The **first full release** (Himawari 3.0) comes after them, for the Mac and the new platforms
together.

1. **More players.** Today the music wallpaper follows only Apple's Music app. Next, it follows
   Spotify, YouTube Music, TIDAL, Amazon Music and Deezer too.
2. **On-device listening insights.** Himawari already sees every song you play. It could keep
   a private listening history across all of those services, classify what you play, and report
   stats and insights back to you, all on your Mac, without training any model on your data.

| Release | Theme | Headline |
|---|---|---|
| **Beta 1.2** | Any player | The wallpaper, gear and CD follow whichever app is playing |
| **Beta 1.3** | Per-player depth and playlists | Spotify and the others get the controls Apple Music has today, where their apps allow it; playlists on the desktop |
| **Beta 1.4** | Styles, part 1: eras and skins | A theme system, the first new eras (1970s turntable, 1980s cassette), skins as files, a Style menu |
| **Beta 1.4.5** | Styles, part 2: genres and customising | The other eras, looks that follow the genre, a customise window with live previews, the changer restyled per era |
| **Beta 1.5** (final Beta 1) | Synced lyrics | The song's words in time with the music, on the deck's display and, if you like, big on the desktop |
| **Beta 2.0** | Your listening, on device | A private listening history and a stats view across every service |
| **Beta 2.1** | Classification and insights | On-device labels (genre, mood, energy, language) and reports about your listening |
| **Core 0.1** | One core for every platform | The rules every Himawari shares (cover matching, lyrics, skins and designs, the gear's maths) in one Rust library, tested once |
| **Linux Beta 1** | Debian and Ubuntu | The wallpaper and the music wallpaper on GNOME (and other desktops), packaged as .deb and Flatpak |
| **Himawari Link** (Mac Beta 2.2, Linux Beta 2) | Your computer, on your TV | What your Mac or Linux PC plays, its cover, levels and lyrics, sent over your home network to a TV, with the remote as the controls |
| **Fire TV Beta 1** | Fire TV (Fire OS) | A full-screen Himawari for the living room: the eras and the music scene at TV size, for what the TV plays and what your computer sends |
| **Himawari 3.0** | First full release (Mac, Linux, Fire TV) | Notarized, auto-updating, polished and documented: everything from Betas 1 and 2, finished, with Linux and Fire TV out of beta beside it |
| **Later** | Android TV and Google TV, Android, Windows | The Fire TV app without Amazon's parts; a live wallpaper on phones; a desktop window on Windows |

Each release ships through the usual pull request and CI, with unit tests for its logic
(see [CONTRIBUTING.md](CONTRIBUTING.md)).

---

## 1 · More players (Betas 1.2 – 1.3)

### Where the coupling is today

Three places assume Apple Music:

| Where | What it assumes |
|---|---|
| `NowPlaying.swift:116` | System Now Playing updates are **ignored** unless they come from Music's process |
| `NowPlaying.swift` (AppleScript) | Controls, volume, repeat, shuffle and the equalizer are all `tell application "Music"` |
| `AudioLevels.swift:63` | The audio tap listens to Music's process |

The helper that reads the system Now Playing stream (`helpers/NowPlayingHelper.m`) already
receives **every** app that reports what it's playing, including Spotify, TIDAL, Amazon Music,
Deezer, and browsers playing YouTube Music or SoundCloud. Himawari just filters the others out.
So the first step is mostly removing a filter and adding a layer that knows what each player can do.

### Design: player sources

A `PlayerSource` protocol in HimawariKit, one implementation per player, chosen by the playing
app's bundle id:

```swift
protocol PlayerSource {
    static var bundleIDs: Set<String> { get }        // e.g. "com.spotify.client"
    var capabilities: PlayerCapabilities { get }     // transport, seek, volume, shuffle, repeat, EQ, motion art
    func send(_ command: PlayerCommand)              // play/pause, next, previous, seek(to:)
    func readDeck(_ done: @escaping (Deck?) -> Void) // volume, shuffle, repeat, where available
}
```

- **`SystemNowPlayingSource`** is the fallback for any app: the title, artist, album, timing and
  exact cover from the system's Now Playing stream. Transport commands go through the same
  MediaRemote route the helper already uses, so play, pause, next, previous and seeking work for
  every player that supports them. That covers most of the experience with no per-app code.
- **Per-app sources** add what an app's own scripting allows (volume, shuffle, repeat, equalizer).
- The gear's controls **light up only for capabilities the source has**. For example, a dimmed
  BASS/TREBLE pair means "this player has no equalizer".
- **Two apps playing at once:** follow the most recently started one, and let the menu pin a player.
- **Animated covers stay an Apple Music feature,** because only Apple's catalog publishes them.
  Every other player gets the CD scene, which already works from any cover.
- **The audio tap follows the playing app's process.** For browser players that means tapping
  the browser, which also hears other tabs. The menu says so.

### The players

| Player | How Himawari would see it | Controls | Extras possible | Risks |
|---|---|---|---|---|
| **Apple Music** | AppleScript + system Now Playing (today) | Full | Animated covers, EQ, repeat/shuffle | — |
| **Spotify** (desktop app) | System Now Playing; Spotify's AppleScript dictionary for its own track id and cover URL | Play/pause, next/previous, seek, volume, shuffle, repeat (AppleScript) | Exact track id for the listening history | Spotify Canvas videos have no public API: don't scrape them |
| **YouTube Music** (web, in Safari/Chrome/Arc) | System Now Playing from the browser's media session | Play/pause, next/previous, seek (where the page supports it) | Could keep the existing YouTube loop of the official video | No official API. Unofficial clients break YouTube's terms: stick to what the browser reports |
| **TIDAL** (desktop app) | System Now Playing | Play/pause, next/previous, seek | Metadata from TIDAL's developer API (optional, needs keys) | API is newer and may change |
| **Amazon Music** (desktop app) | System Now Playing | Play/pause, next/previous | — | No public API for personal data |
| **Deezer** (desktop app) | System Now Playing | Play/pause, next/previous, seek | Deezer's public API for catalog lookups (optional) | — |

Local players (VLC, IINA, Plexamp) come for free through `SystemNowPlayingSource`.

### Milestones

- **Beta 1.2: Any player** (built)
  - The Music-only filter is gone. `PlayerKind` / `PlayerCapabilities` / `PlayerChoice`
    (`PlayerSource.swift`) say which app is playing, what it allows, and whether to follow it;
    Apple Music keeps its AppleScript path, every other app goes through the system stream.
  - The Now Playing helper takes play/pause/next/previous/seek on its input and sends them to the
    playing app (Control Center's remote commands).
  - Capability-aware gear: unsupported controls dim and get no click catcher.
  - The meters tap the playing app, including a browser's helper processes.
  - A **Players** menu: which apps to follow (browsers and other apps start off: they mostly play
    videos), and **Only Follow** to pin one. A paused app never takes over from a playing one.
  - Tests: player detection by bundle id, capabilities, the follow and switching rules, helper
    commands, which controls each player gets, and the tap's process matching.
  - Still to do in a later pull request: moving Apple Music's AppleScript into its own source
    type (`AppleMusicSource`), which Beta 1.3's per-app sources will follow.
- **Beta 1.3: Per-player depth** (released 15 Oct 2026)
  - `SpotifySource` (AppleScript: volume, shuffle, repeat, track id). Browser detection for YouTube
    Music so the CD shows the right cover and the YouTube loop can play.
  - TIDAL, Amazon Music and Deezer sources: just bundle ids and quirks (for example, players that
    report position late).
  - Per-app permission prompts explained in the README (Automation ▸ Spotify, and so on).
  - **Playlists** (below).

### Playlists (Beta 1.3)

The deck shows songs; with playlists it also becomes a **disc changer**: a row of your playlists,
each a disc or a case with its cover, which you can browse and play from the desktop.

**What you can do:**
- **See where you are:** the deck's display shows the playlist (or album) that's playing, and the
  song's place in it ("7 / 24"). The disc's label shows the playlist's name.
- **Up next:** the next few songs, scrolling on the display; click one to jump to it.
- **Switch playlists:** open the changer (a button on the deck, or ⌃⌥⌘P), flip through your
  playlists, and click one to play it. The disc changes with the usual slide.
- **Pin favourites:** pin the playlists you play most so they're always first in the changer.
- **Shuffle and repeat a playlist** with the deck's buttons, where the player supports them.

**What each player allows** (and so what the changer shows):

| Player | Read the current playlist | List your playlists | Play a playlist | Up next / jump to a song |
|---|---|---|---|---|
| **Apple Music** | Yes (AppleScript: `current playlist`) | Yes (`user playlists`, with their artwork) | Yes (`play playlist`) | Yes (its tracks, in order) |
| **Spotify** | The playing context's link, if its AppleScript gives it | No (only through Spotify's Web API, which needs sign-in) | Yes, by link (`play track "spotify:playlist:…"`) | No |
| **TIDAL, Amazon Music, Deezer, web players** | No | No | No | No |

So the full changer is an Apple Music feature. For Spotify you can **pin playlists by their link**
(Share ▸ Copy Link to Playlist) and play them from the changer. For the others, the changer shows
your pinned links, which open in the player. Signing in to a service's API to list playlists is a
possible later option, but it means accounts and tokens, so it isn't in 1.3.

**Design:**
- A `PlaylistSource` capability alongside `PlayerCapabilities` (`.playlists`, `.upNext`), so the
  changer and the up-next display dim the same way the other controls do.
- Playlists are read when the changer opens, not polled. Covers come from the player (Apple
  Music's artwork) or a generated mosaic of the first four song covers.
- The changer is drawn by the gear (so Beta 1.4.5's eras can restyle it: a CD changer, a cassette
  rack, a crate of records).

**Tests:** playlist parsing from AppleScript output, the "7 / 24" position, pinned-link validation
(Spotify playlist links only), and that the changer's controls dim per player.

---

## Styles and skins (Betas 1.4 and 1.4.5)

The side gear and the CD scene are one look today: a black 2000s hi-fi rack and a picture disc.
Betas 1.4 and 1.4.5 make the look a choice, built as **themes** the gear and the scene draw from:
1.4 builds the theme system and the first new eras, 1.4.5 the rest, the genre rules and customising.

### Eras of players

Each era is a layout (what the hardware is and where its controls sit) plus its own skins:

| Era | The player | The disc / media | Skins | In |
|---|---|---|---|---|
| **1970s hi-fi** | Walnut receiver, big tuning dial, analog VU meters | Vinyl on a turntable with a tonearm (the "CD" becomes a record: scrub by turning it) | Walnut, brushed silver | 1.4 |
| **1980s cassette deck** | Twin-deck tape player, spooling reels, LED meters | A cassette whose reels turn; scrubbing winds the tape | Black plastic, chrome "Metal" | 1.4 |
| **1990s portable** | Discman-style player, LCD display | A CD in a clear lid | Silver, translucent colours | 1.4.5 |
| **2000s rack** (today's) | The current CD deck and stereo analyzer | Picture CD | Black, champagne gold | 1.4 (made a theme) |
| **2000s pocket player** | Click-wheel music player | Cover art on a small screen, the wheel scrubs | White, black, colours | 1.4.5 |
| **Today, minimal** | Flat glass panels, large cover, thin waveform | Floating cover card | Light, dark, frosted | 1.4.5 |

The controls stay the same everywhere (play/pause, skip, the progress control, turning to scrub,
volume), so `GearControls` keeps working: each layout just reports where its controls are
(`controlRects`), as the current gear does.

### Looks that follow the genre

A theme can pick its era and skin from the song's genre (the genre in Apple's catalog, from the
lookup Himawari already makes for animated covers), so the desktop matches the music:

- Jazz, soul, classic rock → 1970s hi-fi; synth-pop, 80s → cassette deck; hip-hop, R&B → 2000s rack;
  electronic → minimal with neon accents; classical → walnut, quiet animation.
- You can set your own genre → look rules, pin one look, or let it follow the album's cover colours.

### Customising

- A **Style** menu and a small window to pick era, skin and genre rules, with live previews.
- Per-look options: animation amount, meter type (needles / LEDs / spectrum), label text.
- Skins as simple files (colours, materials, fonts, layout numbers) in
  `~/Library/Application Support/Himawari/Skins/`, so new skins don't need code.

### Milestones

- **Beta 1.4: eras and skins** (built)
  - A `GearTheme` protocol: a layout (where each control sits, reported as `controlRects` so
    `GearControls` keeps working), the drawn hardware, and the media in the middle. Today's 2000s
    rack and picture CD become the first theme, with no visible change.
  - Two new eras: **1970s hi-fi** (walnut receiver and a turntable: the record scrubs like the CD)
    and **1980s cassette deck** (spooling reels; scrubbing winds the tape).
  - **Skins as files** (colours, materials, fonts, layout numbers) in
    `~/Library/Application Support/Himawari/Skins/`, with the built-in ones as examples.
  - A **Style** menu: pick the era and skin.
  - Also in 1.4: the live meters running on battery (the 1.3.1 fix), and any small features
    that come up along the way.
  - **Tests:** each layout's controls stay inside its frame and don't overlap; skin files load and
    reject bad values; switching themes keeps the song, position and playing state.
- **Beta 1.4.5: genres and customising** (built)
  - The other eras: **1990s portable**, **2000s pocket player**, **today, minimal**.
  - **Looks that follow the genre**, with your own genre → look rules, a pinned look, or the
    cover's colours.
  - A **customise window** with live previews: era, skin, genre rules, animation amount, meter type
    (needles, LEDs, spectrum), label text.
  - The **disc changer restyled per era**: a CD changer, a cassette rack, a crate of records.
  - **Tests:** genre → look rules; the customise window's choices round-trip through settings.

---

## Synced lyrics (Beta 1.5, the end of Beta 1) (built)

The words of the song, in time with it, as part of the gear rather than a separate window.

- **Where they show:**
  - On the deck's display, in place of the album line: the line being sung, which scrolls on as
    the song does (each era's display: the fluorescent rack, the receiver's dial, the LCD…).
  - Optionally, **big on the desktop** under the media: the current line bright, the next one
    dimmed, with a soft karaoke sweep across the words where the timing is per word.
- **Where they come from:**
  - **LRCLIB** (lrclib.net): a free, open database of time-synced lyrics, no account or key.
    Looked up by title, artist, album and length, so a remix or a live take doesn't get the studio
    words.
  - **Apple Music's own lyrics** (the track's `lyrics`, through AppleScript) when LRCLIB has
    none: plain text, so they're shown as pages that turn with the song, not line by line.
  - Nothing found: nothing shown, and the display keeps the album.
- **Timing:** lines follow the gear's own steady clock (the one the time display uses), so they
  stay in step through seeks, scrubs and pauses. A small offset (±0.5 s steps) fixes a file
  that runs early or late, saved per song.
- **Privacy:** only the song's title, artist, album and length are sent, to LRCLIB, and only when
  lyrics are switched on. Results are cached on the Mac.
- **Menu:** Lyrics ▸ Off / On the Display / On the Display and Desktop, plus the timing offset.
- **Tests:** parsing LRC files (timestamps, several stamps on one line, offsets, word timing),
  choosing the right result (length and album matching), the line for a given position, and
  plain lyrics split into pages.
- **Also in 1.5: your own eras.** Design files lay out the panels as blocks and pick the media; a
  skin wears one by its id. A 1980s Boombox ships as the example. Skin and design files reload as
  they're saved.

---

## 2 · Your listening, on device (Betas 2.0 – 2.1)

> Built by me, hands-on, as a machine-learning learning project: the plan below is a starting
> point, not a spec to hand off.

Machine learning here is **only for classifying and reporting**: sorting what you play into
categories (genre, mood, energy, era, language) and turning your history into stats and insights
for you. **No model is trained on your listening data.** Himawari runs fixed, pre-trained
classifiers and plain statistics, on the Mac.

### Principles

These hold for every feature in this section:

1. **Nothing leaves the Mac.** No accounts, no upload, no analytics.
2. **No training on your data.** Only fixed, pre-trained classifiers (Apple's built-in ones, or a
   model shipped inside Himawari) and statistics. Your history is never used to train or tune a model.
3. **Off until you turn it on.** You can see, export (JSON/CSV) and delete everything, any time.
4. **Only what's needed.** A record of what played and how much of it, never audio. The meters'
   audio measurements are never stored; at most a few derived numbers per song.
5. **Respect each service's terms.** Spotify's developer policy, for example, restricts putting its
   content into machine-learning models. Himawari never calls a service's API to gather data for
   this, works only from what your own Mac observes playing, and each service's terms get a
   careful read before release.

### Beta 2.0: A private listening history and stats

**What gets recorded:** one row per play, in a local SQLite database (SwiftData or GRDB) in
`~/Library/Application Support/Himawari/`.

| Field | From |
|---|---|
| title, artist, album, duration | system Now Playing |
| source app, source track id (if the app gives one) | `PlayerSource` |
| started at, seconds listened, skipped? (< 30 s or under half the song) | Himawari's position tracking |
| genre, release year | iTunes Search API results Himawari already fetches for covers |
| time of day, weekday, on battery / plugged in | the Mac |

**One song, many services.** The same song played on Spotify and on Apple Music should count as
one. Matching is on-device and rule-based:
- normalised title and artist, plus duration within 3 s;
- the album-matching rules already tested for animated covers (`albumKey`, `sameAlbum`, `artistNames`);
- for borderline cases, a similarity score from Apple's pre-trained `NaturalLanguage` sentence
  embeddings on "title — artist";
- the ISRC (the industry-standard recording code) from Apple's catalog via MusicKit, where you
  allow it.

**Stats view** (a window from the menu, and an optional desktop panel like the clock):
- top artists, songs and albums by week, month and year, across all services or per service;
- listening time, skip rate, "on repeat right now", and new artists discovered this month;
- when you listen: a weekday × hour heat map, and your morning versus late-night listening;
- a year-in-review that's actually yours, computed locally.

**Wallpaper tie-ins:**
- a weekly "your top album" CD;
- the clock showing your listening streak;
- the ambient fill colours following the week's most-played covers.

**Tests:** play/skip classification, cross-service matching (positive and negative pairs), and
aggregation queries on a fixture database.

### Beta 2.1: Classification and insights

Each song gets labels from fixed classifiers, and the reports use them to describe your listening.

**Classifiers** (pre-trained, run on the Mac, never retrained):

| Label | From | Notes |
|---|---|---|
| **Genre** | The catalog genre (iTunes Search API), normalised to a small set of families | Metadata, no model needed; the fallback for everything else |
| **Language** | `NaturalLanguage`'s built-in language identifier on the title (and album) | Short text, so only confident results are used |
| **Sound character** | Apple's built-in `SoundAnalysis` classifier on a few seconds of the audio the meters already hear, while it plays | Keeps only the top labels (e.g. "acoustic guitar", "electronic", "speech/podcast"), never the audio |
| **Energy and mood** | A few numbers from the meters' spectrum (loudness, brightness, tempo estimate), sorted into calm / steady / energetic by fixed thresholds | Simple, explainable rules |
| **Era** | Release year from the catalog, grouped by decade | — |

**Reports and insights** built from those labels and the stats:
- your mix by genre, language, energy and era, and how it shifts by time of day and weekday
  ("Monday mornings are 70% calm acoustic");
- per-service profiles: what you play on Spotify versus Apple Music versus the browser;
- changes over time: "more electronic this month than last", "a new language in your top 20";
- a weekly and yearly report, viewable in the stats window and exportable as PDF or image.

**Suggestions without training:** simple, explainable picks from the history and the labels,
not a learned recommender:
- "haven't played in a while": favourites you've drifted from;
- "more like this": songs in your history with the same labels as what's playing;
- from Apple's public catalog, by artist or genre lookup, other albums by artists you play.

Anything suggested opens in the player you choose: Apple Music by catalog id, others by a search link.

**Measuring it:**
- classifier accuracy on a small, hand-labelled fixture set;
- a "that's wrong" button on any label, which overrides it for that song (stored as your
  correction, not used to train anything).

### Milestones

- **Beta 2.0:** listening history (opt-in), cross-service matching, the stats window and desktop
  panel, export and delete, and the wallpaper tie-ins.
- **Beta 2.1:** the classifiers, the reports and insights, rule-based suggestions, label
  corrections, and fixture tests for each classifier.

---

## Himawari beyond the Mac: Linux, your TV, and more

Before Himawari 3.0, Himawari goes to other platforms (the Beta 2 listening work carries on beside
it). They share as much as can be shared: the
rules, the file formats and the looks. Each one gets its own app, drawn with its own platform's
tools, because a desktop wallpaper, a Linux background and a TV screen are different things.

| Platform | What Himawari is there | Built with | Order |
|---|---|---|---|
| **Linux** (Debian, Ubuntu) | The desktop wallpaper, as on the Mac | Rust, GTK 4, GStreamer, MPRIS, PipeWire | First |
| **Fire TV** (Fire OS) | A full-screen music display for the living room | Kotlin, Jetpack Compose for TV, Media3 | Second |
| **Android TV, Google TV** | The Fire TV app, without Amazon's parts | (the same) | With Fire TV, as its own build |
| **Android** phones and tablets | A live wallpaper (the music scene behind your home screen) | Kotlin, `WallpaperService` | Later |
| **Windows** | The desktop wallpaper, as on the Mac and Linux | Rust core, a window behind the desktop icons (the WorkerW layer) | To explore |

### himawari-core: one set of rules

A Rust library that every new Himawari builds on, with **UniFFI** bindings for Kotlin (Fire TV,
Android) and Swift (so the Mac can move onto it before 3.0), and plain Rust for Linux.

- **What's in it:** album matching for animated covers and title cleaning for web players; the
  catalog and LRCLIB lookups; LRC parsing and the line for a position; skin and design files
  (reading, checking, the built-in skins); the design blocks' layout; the gear's maths (the VU
  scale, the tonearm, the tape packs); genre rules and cover tints; version checks for updates.
- **Tests once:** the Mac's tests become shared JSON fixtures (inputs and expected answers) that the
  core's tests and the Mac's own Swift tests both run, so the apps can't drift apart while the Mac
  still uses its own code.
- **Core 0.1** is done when its fixtures pass and the Linux app builds on it.

### Linux Beta 1: Debian and Ubuntu

Then the wallpaper comes to Linux, starting as its own beta. It began from Hanabi for GNOME,
so this is something of a homecoming, but it's a separate implementation: none of Hanabi's
(GPL-3.0) code is used, as with the Mac app.

The Mac code can't be reused directly (AppKit, AVFoundation, Core Animation and Core Audio
are Apple's), but the design can: the same parts, each with a Linux counterpart.

| Part | Mac | Linux |
|---|---|---|
| Wallpaper window under the icons | desktop-level `NSWindow` | GNOME: a small GNOME Shell extension that places the window as the background (GNOME has no layer-shell); KDE, Sway and other wlroots desktops: `wlr-layer-shell` (background layer); X11: a desktop-type window |
| Video playback | AVFoundation | GStreamer (hardware decoding via VA-API) |
| Drawing the gear and CD | Core Animation | GTK 4 (GSK, GPU-drawn) |
| What's playing, and controls | MediaRemote + AppleScript | **MPRIS** over D-Bus: the standard every Linux player speaks (Spotify, browsers, Rhythmbox, VLC…), with play/pause/seek/volume, and even shuffle and repeat |
| VU meters and spectrum | Core Audio process tap | a PipeWire monitor stream of the player's output |
| Animated covers | Apple Music's public pages | the same lookup (it's just the web) |
| Lock screen | Aerial swap | out of scope at first (GNOME's lock screen is drawn by the shell) |

- **Language:** Rust with GTK 4, GStreamer, `zbus` (MPRIS) and PipeWire bindings: fast, safe and
  well supported on both distributions. The rules come from **himawari-core** (below), so the Linux
  and Mac apps agree.
- **Skins and designs:** the same JSON files as on the Mac. A skin made on one works on the other.
- **Packaging:** a `.deb` for Debian 13 and Ubuntu 24.04 LTS and later, and a Flatpak (Flathub) for
  everyone else.
- **Linux Beta 1 scope:** your own video wallpaper, the music wallpaper (animated covers and the
  CD), the side gear with play/pause/skip/seek/volume through MPRIS, and the meters. Then, as on the
  Mac: Players, playlists (MPRIS has a playlists interface), styles.
- **Tests and CI:** unit tests for the ported logic, and a GitHub Actions job that builds the
  `.deb` and Flatpak on Ubuntu.

### Himawari Link: your computer, on your TV

A small protocol for showing what one Himawari plays on another screen in the house.

- **Finding each other:** Bonjour / mDNS (`_himawari._tcp`) on the local network, and a four-digit
  code shown on the TV the first time a computer connects. Nothing goes through the internet.
- **What's sent** (WebSocket, JSON): the song (title, artist, album, length, position, playing),
  the cover (or its address), the animated cover's stream address, the style in use, the live
  levels (about 20 a second, for the meters), and the lyric line. The TV sends the controls back:
  play/pause, skip, seek, volume.
- **Mac Beta 2.2 and Linux Beta 2** send; the Fire TV app receives. Two Macs can show each other too.
- **Tests:** the message format round-trips; a recorded session plays back the same on both ends.

### Fire TV Beta 1

On a TV, Himawari isn't a wallpaper behind icons: it's a full-screen app you open, or leave on,
while music plays. The scene and the gear are laid out for a TV across the room.

- **What it shows:**
  - The music scene at TV size: the animated cover when the album has one (Apple Music's loops
    play in Media3's HLS player), or the cover on the era's media, with the side gear and lyrics.
  - The same eras, skins and designs as the desktop, from the same JSON files (copied over Link, or
    added from a web page the app serves on your network).
- **What's playing:**
  - **From your computer, over Himawari Link:** the full experience, with real levels for the meters.
  - **On the TV itself** (Amazon Music, Spotify, YouTube Music and other Fire TV apps): through
    Android's media sessions. That needs Fire OS's notification access, which some Fire TV models only
    allow from the developer tools (a one-time `adb` command, explained in the app). The meters animate
    by themselves there: Fire OS doesn't let one app hear another's sound.
- **The remote is the controls:** the D-pad moves between the gear's controls, select presses them,
  left and right on the wheel scrub, and play/pause works as on any player. The Menu button opens Style.
- **Staying on:** it keeps the screen awake while music plays and dims after a while when it's paused.
  Fire OS doesn't offer third-party screensavers in Settings; an `adb` setting can make Himawari the
  screensaver, for people who want that.
- **Packaging:** the Amazon Appstore, and an APK to sideload.
- **Vega OS:** Amazon's newer Fire TV devices run Vega OS, which runs React Native apps rather than
  Android ones. Fire TV Beta 1 targets Fire OS (most devices in homes); a Vega version is a later,
  separate port, once it's clear what native code Vega apps may use.
- **Tests and CI:** the core's fixtures through its Kotlin bindings, Compose UI tests for focus
  order on the gear, and a GitHub Actions job that builds the APK.

### Later

- **Android TV and Google TV:** the Fire TV app without Amazon's parts (the Play Store, Google TV's
  own screensaver API).
- **Android phones and tablets:** the music scene as a live wallpaper (`WallpaperService`), following
  the phone's media sessions; lyrics and styles as on the desktop.
- **Windows:** worth exploring once the core exists: a window parented behind the desktop icons,
  Media Foundation for video, the Windows media session for what's playing.

## Himawari 3.0: the first full release

After Beta 2 and the first betas on Linux and Fire TV, Himawari gets finished rather than extended, on every platform it has reached. Versions go straight to **3.0** (the
1.x and 2.x numbers belong to the betas, and their tags already exist).

- **Trust and installing:** a Developer ID signature and **notarization** (no more right-click ▸
  Open), and **automatic updates** with signed feeds (Sparkle), in place of Beta 1.5.1's simple
  one-click updater.
- **First run:** a short welcome that picks a video and asks for each permission at the moment
  it's needed, with what it's for.
- **A Settings window** in place of the long menu, with the Players, Style and Disc Changer
  options in one place; the menu keeps the everyday switches.
- **Polish:** accessibility (VoiceOver labels on the gear and changer, reduced motion,
  reduced transparency), localisation-ready strings, and a pass with the apple-design guidelines
  (springs that start from the current value, consistent motion and materials).
- **Reliability:** tests around every pure piece, a performance budget checked in CI (idle CPU,
  memory), crash reporting that stays local unless you choose to send a report.
- **Docs:** an updated code report, a user guide on the project page, a privacy statement.
- Less reliance on undocumented behaviour where Apple now offers a public way.

## Risks and open questions

- **Private APIs.** Following other players leans further on MediaRemote, the same undocumented
  system Now Playing stream Himawari already uses. A macOS update could break it. Keep the
  AppleScript paths working for Apple Music and Spotify as the fallback.
- **Terms of service.** Each service's developer terms must be checked before shipping its source,
  especially on stored metadata and machine learning. When in doubt, use only what the Mac
  observes and never call that service's API.
- **Browsers.** A web player's Now Playing comes from the browser, so Himawari can't always tell
  YouTube Music from a YouTube video in another tab. Heuristics: page title, album field, duration.
- **Battery.** Recording plays costs nothing. Classifying a song's sound runs once per song,
  briefly, and the reports are built off the main thread.
- **Scope.** Beta 1.2 alone makes Himawari useful to most people who don't use Apple Music. Ship it,
  and finish Beta 1 with Betas 1.3 to 1.5, before starting the listening work in Beta 2.
- **Fire OS limits.** Reading other apps' media sessions needs notification access (granted with
  `adb` on some models), apps can't hear other apps' sound, and third-party screensavers aren't in
  Settings. Himawari Link sidesteps all three for music played on a computer.
- **Vega OS.** Amazon is moving new Fire TV devices to Vega OS (React Native). Fire OS devices will be
  around for years, but a Vega port may be needed sooner than Android TV.
- **App stores.** The animated covers come from Apple Music's public pages and the lyrics from
  LRCLIB; Amazon's and Google's reviews need to accept that, and the app must say where both come from.
- **Two codebases.** The Mac stays Swift; the core is Rust. Shared fixtures keep them in agreement
  until the Mac moves onto the core.

## Done

- **Interactive side panels** (`GearControls.swift`): the transport buttons, the progress ladder,
  the jog wheel and the VOLUME knob control Music.
- **Interactive CD**: grab and turn the disc to scrub through the song, with a synthesized sound
  of the disc moving.
- **BASS and TREBLE** (Beta 1.1): shelves on a "Himawari" equalizer preset in Music. Back at 0 / 0
  puts the previous equalizer back. Double-click a knob for flat.
- **REPEAT / SHUFFLE** (Beta 1.1): lit from Music's real settings and clickable to switch them.
- **Just the wallpaper** (Beta 1.1.2): Himawari is the wallpaper and its desktop clock, now built in.
- **Bug-fix releases** (Betas 1.1.3, 1.1.4): see the release notes and `docs/report/10-health-report.md`.
- **Tests and CI**: 33 unit tests, and every change goes through a pull request and CI.
