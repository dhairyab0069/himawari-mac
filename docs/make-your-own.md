# Make your own look: a cyberpunk skin, step by step

This walks through making a cyberpunk look for Himawari's side gear, from a copy of a built-in skin
to a whole era of your own. Every step is a small JSON file you edit in any text editor. Himawari
reloads it as soon as you save, so the desktop changes while you work.

The files for each step are next to this page, in [`make-your-own/`](make-your-own/). The finished
look also ships with Himawari: pick **Cyberpunk ▸ Neon** in **Style…**.

## 0. Start from a built-in skin

<img src="make-your-own/0-start.png" width="720" alt="Today's dark glass panels, the starting point">

1. Open **Himawari menu ▸ Style…** and pick **Today, Minimal ▸ Dark**.
2. Press **Make My Own…**. Himawari saves a copy as `my-minimal-dark.json` in
   `~/Library/Application Support/Himawari/Skins/`, opens it, and selects it.

The copy lists every setting the skin has. You only need to keep what you change, plus the five
lines that say what the skin is:

```json
{
  "format": 1,
  "id": "my-neon",
  "name": "My Neon",
  "era": "minimal",
  "base": "minimal-dark"
}
```

`base` is the built-in skin everything else comes from. `id` is the file's name for the skin:
lowercase letters, digits and dashes.

## 1. Colours

<img src="make-your-own/1-colours.png" width="720" alt="The same panels, now with cyan lettering and magenta lamps and levels">

Add the four colours that light the gear ([1-colours.json](make-your-own/1-colours.json)):

```json
"colors": {
  "display": "#00F0FF",
  "accent": "#FF2BD6",
  "peak": "#FFE600",
  "label": "#FF2BD6"
}
```

| Colour | What it lights |
|---|---|
| `display` | The song, the time, the progress, the waveform |
| `accent` | The level lines, the dot on the ring, lamps |
| `peak` | The loudest segments of LED meters |
| `label` | The printing on the faceplate |

Colours are `#RRGGBB`, or `#RRGGBBAA` to make them see-through.

## 2. Lettering

<img src="make-your-own/2-lettering.png" width="720" alt="The same, with the song in a monospaced font and the model names printed in magenta">

Give the gear its own names and fonts ([2-lettering.json](make-your-own/2-lettering.json)):

```json
"brand": "NEO-TOKYO",
"models": { "left": "SOUND SYSTEM   NT-2099", "right": "SIGNAL ANALYZER   NT-2099" },
"fonts": { "brand": "Futura-CondensedExtraBold", "display": "Menlo-Bold" }
```

Fonts are the names Font Book shows under **Show Font Info** (PostScript names). `null` goes back to
the system font. Today's minimal era prints the model names; the brand shows in eras with a
header, like the one in step 4.

## 3. Materials and shape

<img src="make-your-own/3-materials.png" width="720" alt="Near-black panels with cut corners, a glowing magenta edge, a faint grid, scan lines and circuit traces">

Make the panels near-black and give them the heads-up-display material
([3-materials.json](make-your-own/3-materials.json)):

```json
"material": "hud",
"layout": { "corner": 16 },
"colors": {
  "plate": ["#0E0A1CEE", "#07050FEE", "#0B0817EE"],
  "button": ["#1C1236", "#0A0618"],
  "knob": ["#2A1A48", "#0A0618"],
  ...
}
```

- `hud` cuts the corners off (by `corner` points), draws a tube of light in the `accent` colour round
  the edge, and fills the plate with a faint grid, scan lines and circuit traces, with bracket marks
  in the corners. `neon` is the glowing edge alone; the others are `brushed`, `chrome`, `plastic` and
  `matte`.
- `plate` is the faceplate's top, middle and bottom. The `EE` on the end lets a little of the
  wallpaper's glow through.

It still has the minimal era's layout, though: plain type, bare symbols, a thin ring. The next step
changes that.
- The layout can also set `columnWidth` (200 to 360), `gap` (4 to 16) between buttons, and
  `caseWidth` (0 to 30) for a wooden case.

## 4. Your own era

<img src="make-your-own/4-your-own-era.png" width="720" alt="A new layout: a framed HUD display, outlined buttons and a turning reactor ring with readouts on the left; LED meters, a spectrum, readouts and segmented knobs on the right; in the middle the cover as a hologram over a glowing emitter">

So far the skin has only changed how the minimal era looks. A **design** changes what's on the
panels and in the middle. Save [my-cyberpunk.json](make-your-own/my-cyberpunk.json) in
`~/Library/Application Support/Himawari/Designs/`:

```json
{
  "format": 1,
  "id": "my-cyberpunk",
  "name": "My Cyberpunk",
  "media": "hologram",
  "left": [
    { "block": "header" },
    { "block": "display", "style": "hud", "height": 160 },
    { "block": "buttons", "style": "hud", "height": 38 },
    { "block": "wheel", "style": "reactor", "label": "NEURAL SCRUB" },
    { "block": "readout", "height": 50 }
  ],
  "right": [
    { "block": "header" },
    { "block": "meters", "style": "leds", "height": 70 },
    { "block": "spectrum" },
    { "block": "readout", "height": 62 },
    { "block": "knobs", "style": "hud", "height": 84 }
  ]
}
```

- `hologram` projects the cover up from a glowing emitter: turned a little away in space,
  see-through, scan-lined, with an iridescent sheen, colour fringes at its edges, a band of light
  sweeping down it and the odd flicker.
- The `hud` display is framed with cut corners, scan lines and a tab; `hud` buttons are outlined;
  the `reactor` wheel is a ring of dashes and arcs around a glowing core that turns slowly by
  itself (and when you scrub); `hud` knobs are rings of lit segments; `readout` is lines of
  made-up system data.

Each panel is a list of blocks, stacked from the top. A block with a `height` gets that many points
(fewer on a short screen). The ones without a height share what's left.

Then add one line to the skin ([4-your-own-era.json](make-your-own/4-your-own-era.json)):

```json
"design": "my-cyberpunk"
```

In **Style…** the skin now has a section of its own, **My Cyberpunk**.

| Block | Styles | Notes |
|---|---|---|
| `header` | | The brand and the model name |
| `display` | `vfd`, `lcd`, `glass`, `dial`, `hud` | The song, the time and the progress. `dial` is a tuning dial whose pointer travels through the song |
| `buttons` | `rounded`, `keys`, `round`, `flat`, `bare`, `hud` | Previous, play/pause, next, stop, eject |
| `wheel` | `knurled`, `ring`, `clickwheel`, `reactor` | Turn it to scrub. A `label` prints under it |
| `meters` | `needles`, `leds`, `spectrum` | The left and right levels |
| `spectrum` | | Ten bands |
| `knobs` | `classic`, `flat`, `touch`, `hud` | Bass, treble, volume |
| `grille`, `toggles`, `sliders`, `gamepad`, `readout`, `power`, `spacer` | | For looks: a speaker, switches, equalizer sliders, a D-pad and face buttons, system readouts, the power switch, a gap |

A design needs exactly one `display`, one `buttons`, one `wheel` and one `knobs`, on either side.

`media` is what plays in the middle: `cd`, `record`, `cassette`, `discman` (a CD under a portable
player's lid), `player` (a pocket player), `card` (the cover floating), `cartridge` (a handheld's
game cartridge with the cover on its label) or `hologram`.

## 5. Share it

Send the skin and the design to a friend. In **Style…** they press **Import…** for the skin and put
the design in their Designs folder. If their own skin already uses the same id, the imported one
gets a new id, so nothing is overwritten.

## When something's wrong

A file with a mistake is skipped, and **Style…** lists it in orange with the reason, for example:

```
my-neon.json: "colors.display": colours are written #RRGGBB or #RRGGBBAA
Designs/my-cyberpunk.json: "left[2].style": one of rounded, keys, round, flat, bare
```

Fix the file and save it: it loads as soon as it's right.
