# Roadmap

What comes after the Beta 1.1 series. Betas 1.2 to 1.4 are the **last of Beta 1**; the listening
work starts **Beta 2**, which I'm building myself, hands-on, as part of learning machine learning.

1. **More players.** Today the music wallpaper follows only Apple's Music app. Next, it follows
   Spotify, YouTube Music, TIDAL, Amazon Music and Deezer too.
2. **On-device listening insights.** Himawari already sees every song you play. It could keep
   a private listening history across all of those services, classify what you play, and report
   stats and insights back to you, all on your Mac, without training any model on your data.

| Release | Theme | Headline |
|---|---|---|
| **Beta 1.2** | Any player | The wallpaper, gear and CD follow whichever app is playing |
| **Beta 1.3** | Per-player depth and playlists | Spotify and the others get the controls Apple Music has today, where their apps allow it; playlists on the desktop |
| **Beta 1.4** (final Beta 1) | Styles and skins | CD player layouts from different eras, skins for each, and looks that follow the genre |
| **Beta 2.0** | Your listening, on device | A private listening history and a stats view across every service |
| **Beta 2.1** | Classification and insights | On-device labels (genre, mood, energy, language) and reports about your listening |

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
- **Beta 1.3: Per-player depth** (built; releases Tue 13 Oct 2026, 6:41 PM ET)
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
- The changer is drawn by the gear (so Beta 1.4's eras can restyle it: a CD changer, a cassette
  rack, a crate of records).

**Tests:** playlist parsing from AppleScript output, the "7 / 24" position, pinned-link validation
(Spotify playlist links only), and that the changer's controls dim per player.

---

## 1.4 · Styles and skins (Beta 1.4, the final Beta 1)

The side gear and the CD scene are one look today: a black 2000s hi-fi rack and a picture disc.
Beta 1.4 makes the look a choice, built as **themes** the gear and the scene draw from.

### Eras of players

Each era is a layout (what the hardware is and where its controls sit) plus its own skins:

| Era | The player | The disc / media | Skins |
|---|---|---|---|
| **1970s hi-fi** | Walnut receiver, big tuning dial, analog VU meters | Vinyl on a turntable with a tonearm (the "CD" becomes a record: scrub by turning it) | Walnut, brushed silver |
| **1980s cassette deck** | Twin-deck tape player, spooling reels, LED meters | A cassette whose reels turn; scrubbing winds the tape | Black plastic, chrome "Metal" |
| **1990s portable** | Discman-style player, LCD display | A CD in a clear lid | Silver, translucent colours |
| **2000s rack** (today's) | The current CD deck and stereo analyzer | Picture CD | Black, champagne gold |
| **2000s pocket player** | Click-wheel music player | Cover art on a small screen, the wheel scrubs | White, black, colours |
| **Today, minimal** | Flat glass panels, large cover, thin waveform | Floating cover card | Light, dark, frosted |

The controls stay the same everywhere (play/pause, skip, the progress control, turning to scrub,
volume), so `GearControls` keeps working: each layout just reports where its controls are
(`controlRects`), as the current gear does.

### Looks that follow the genre

A theme can pick its era and skin from the song's genre (the catalog genre Himawari already looks
up), so the desktop matches the music:

- Jazz, soul, classic rock → 1970s hi-fi; synth-pop, 80s → cassette deck; hip-hop, R&B → 2000s rack;
  electronic → minimal with neon accents; classical → walnut, quiet animation.
- You can set your own genre → look rules, pin one look, or let it follow the album's cover colours.

### Customising

- A **Style** menu and a small window to pick era, skin and genre rules, with live previews.
- Per-look options: animation amount, meter type (needles / LEDs / spectrum), label text.
- Skins as simple files (colours, materials, fonts, layout numbers) in
  `~/Library/Application Support/Himawari/Skins/`, so new skins don't need code.

### Milestones

- **Beta 1.4:** a `GearTheme` protocol that the current gear becomes the first theme of; two new eras to
  start (1970s turntable and 1980s cassette); skins as files; genre rules; the Style menu.
  Other eras follow in point releases.
- **Tests:** each layout's control positions stay inside its frame and don't overlap; genre → look
  rules; skin files load and reject bad values.

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
  and finish Beta 1 with Betas 1.3 and 1.4, before starting the listening work in Beta 2.

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
