# Contributing

## Workflow

1. Branch from `main` (`git switch -c fix/short-name`).
2. Make the change; keep commits focused, with messages that say what changed and why.
3. `swift test`, then `./install.sh` and try it on your desktop.
4. Open a pull request. Fill in the template: what, why, how it was tested, the checklist.
5. CI builds (release, warnings as errors), runs the unit tests, compiles the Now Playing helper
   and checks the scripts. `main` only accepts pull requests that pass.
6. Review the diff (yourself, a collaborator, or `/code-review` in Claude Code), fix what's found,
   then squash-merge. Don't rewrite `main`'s history.

## Tests

`swift test` runs three suites:

| Suite | Covers |
|---|---|
| `HimawariKitTests` | album matching for animated covers, name normalising, HLS stream choice, EQ tone bands, wallpaper brightness readings |
| `HimawariTests` | jog-wheel / CD turn maths, scrub clamping, the VU scale, where a cover goes on the CD |
| `HimawariClockTests` | 12/24-hour, Swatch .beats, decimal time, time in words, tick intervals |

When you fix a bug in logic, first write a test that fails, then make it pass. Code that talks to
macOS (windows, AVFoundation, Core Audio, AppleScript) is checked by hand with the steps in the
pull request template; pull its decisions out into pure functions where you can, so they can be tested.

## Releases

Bump `CFBundleShortVersionString` / `CFBundleVersion` in `Resources/Info.plist` and the DMG name in
the README, merge, tag `vX.Y.Z`, run `UNIVERSAL=1 scripts/make_dmg.sh`, and attach the DMG to a
GitHub release with notes.
