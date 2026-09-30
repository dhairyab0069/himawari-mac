#!/bin/bash
# Himawari's weekly maintenance bot. launchd runs this every Monday at 14:00
# (or at the next wake, if the Mac was asleep then).
#
#   1. Dependencies are updated: Homebrew and everything it installed
#      (including Ghostty), and the Rust toolchain.
#   2. Claude Code checks the project against the current macOS / Swift and
#      fixes only what's broken or deprecated. It may edit files and run
#      builds, nothing else.
#   3. Himawari (with its desktop clock) is rebuilt. If that
#      passes and code changed, it's committed and reinstalled (./install.sh).
#      If the build fails, every change is rolled back.
#   4. You get a notification, and a log in maintenance/logs/.
#
# Run by hand:  ./maintenance/weekly.sh            (full run)
#               ./maintenance/weekly.sh --dry-run  (build + notify only, no Claude)
set -uo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

REPO="$HOME/hanabi-mac"
LOG="$REPO/maintenance/logs/$(date +%Y-%m-%d).log"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
cd "$REPO" || exit 1

notify() { osascript -e "display notification \"$1\" with title \"Himawari maintenance\"" || true; }
echo "===== $(date) ====="

BEFORE=$(git rev-parse HEAD)
if [ -n "$(git status --porcelain)" ]; then
    echo "Uncommitted changes in the repo; skipping so nothing of yours is touched."
    notify "Skipped: you have uncommitted changes in ~/hanabi-mac."
    exit 0
fi

# 1. Dependencies (each step is allowed to fail without stopping the run).
DEPS="skipped (dry run)"
if [ "${1:-}" != "--dry-run" ]; then
    echo "== Updating dependencies"
    export HOMEBREW_NO_INSTALL_CLEANUP=1
    brew update && brew upgrade && brew upgrade --cask --greedy ghostty && brew cleanup -s \
        && DEPS="Homebrew + Ghostty updated" || DEPS="some Homebrew updates failed (see log)"
    rustup update stable || DEPS="$DEPS; rustup update failed"
    echo "Dependencies: $DEPS"
    echo
fi

# 2. Code maintenance.
if [ "${1:-}" != "--dry-run" ]; then
    claude -p "$(cat maintenance/prompt.md)" \
        --model claude-opus-5 \
        --permission-mode dontAsk \
        --allowedTools "Read Glob Grep Edit Write Bash(swift build:*) Bash(swift --version) Bash(sw_vers:*) Bash(git diff:*) Bash(git status:*) Bash(git log:*)" \
        --max-budget-usd 2 \
        --no-session-persistence
    echo
fi

# Verify with a clean release build, whatever Claude said.
if ! ./build.sh; then
    echo "Build FAILED; rolling back to $BEFORE"
    git reset --hard "$BEFORE" && git clean -fdq -e maintenance/logs
    ./build.sh >/dev/null 2>&1 || true
    notify "Build failed this week. Changes rolled back; see maintenance/logs/$(date +%Y-%m-%d).log"
    exit 1
fi

if [ -z "$(git status --porcelain)" ]; then
    echo "No changes needed."
    notify "All good. Himawari builds cleanly, no code changes needed. $DEPS."
    exit 0
fi

git add -A
git -c user.name="Himawari maintenance bot" -c user.email="bhatia.dh@northeastern.edu" \
    commit -qm "Weekly maintenance $(date +%Y-%m-%d)"
echo "Committed: $(git log --oneline -1)"

# Install the new build. (After a code change macOS asks
# again once for Desktop / Accessibility access: the apps are ad-hoc signed, so
# every new build looks like a new app to it.)
./install.sh
notify "Updated: $(git log -1 --format=%s). $DEPS. Changes: git -C ~/hanabi-mac show"
