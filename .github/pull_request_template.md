## What and why

<!-- What does this change, and what problem does it solve? Link the issue if there is one. -->

## How it was tested

- [ ] `swift test` passes (CI runs it too)
- [ ] Installed with `./install.sh` and tried on a real desktop
- [ ] Checked the cases this touches: <!-- e.g. music playing / paused, CD scene, animated cover, a second display, Battery Saver, sleep and wake -->

## Review checklist

- [ ] No work on the main thread that can block (network, AppleScript, file I/O)
- [ ] Timers, observers, processes and audio objects are torn down
- [ ] Closures that outlive the call capture `self` (and windows) weakly
- [ ] Late async results are checked against the current song / generation
- [ ] New logic that can be a pure function is one, with a unit test
- [ ] README / ROADMAP / docs/report updated if behaviour changed
