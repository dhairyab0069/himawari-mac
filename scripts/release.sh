#!/bin/bash
# Publishes a Himawari release that's already merged to main:
#   scripts/release.sh 1.3
# Checks main is clean, at that version and green in CI; runs the tests; builds the universal DMG;
# tags; creates the GitHub release in himawari-mac and himawari-io (with the code report); points
# the README and the project page at the new DMG. Release notes come from docs/release-notes/<v>.md.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin"
V="${1:?version, e.g. 1.3}"
CHECKOUT="$(cd "$(dirname "$0")/.." && pwd)"
SITE="$HOME/himawari-io"
notify() { osascript -e "display notification \"$1\" with title \"Himawari release\"" || true; }
fail() { echo "FAILED: $1"; notify "Release $V didn't go out: $1"; exit 1; }
echo "===== $(date) releasing $V ====="

# Build from exactly what's on GitHub's main, in a fresh worktree: your own checkout (and any
# local commits the weekly bot made) is left alone.
cd "$CHECKOUT"
git fetch -q origin main --tags || fail "couldn't fetch"
REPO="$(mktemp -d)/himawari-$V"
git worktree add -q --detach "$REPO" origin/main || fail "couldn't make a worktree"
trap 'cd "$CHECKOUT"; git worktree remove --force "$REPO" 2>/dev/null || true' EXIT
cd "$REPO"
PLIST_V=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
[ "$PLIST_V" = "$V" ] || fail "main is at version $PLIST_V, not $V"
[ -f "docs/release-notes/$V.md" ] || fail "no docs/release-notes/$V.md"
gh release view "v$V" -R dhairyab0069/himawari-mac >/dev/null 2>&1 && fail "v$V is already released"
CI=$(gh run list -R dhairyab0069/himawari-mac --branch main --limit 1 --json conclusion -q '.[0].conclusion')
[ "$CI" = "success" ] || fail "CI on main is '$CI'"

swift test 2>&1 | tail -3
swift test >/dev/null 2>&1 || fail "unit tests"
UNIVERSAL=1 scripts/make_dmg.sh | tail -1
DMG="build/Himawari-$V.dmg"
[ -f "$DMG" ] || fail "no DMG"

cp "$CHECKOUT/build/Himawari-Code-Report.pdf" build/ 2>/dev/null || true
[ -f build/Himawari-Code-Report.pdf ] || fail "no code report PDF in $CHECKOUT/build"
git tag "v$V" && git push -q origin "v$V"
for r in himawari-mac himawari-io; do
    extra=(); [ "$r" = himawari-io ] && extra=(--target main)
    gh release create "v$V" "$DMG" build/Himawari-Code-Report.pdf -R "dhairyab0069/$r" \
        --title "Himawari Beta $V" --notes-file "docs/release-notes/$V.md" "${extra[@]}"
done

# The README's download links, through a pull request (main is protected).
OLD=$(grep -o 'Himawari-[0-9.]*\.dmg' README.md | head -1)
if [ "$OLD" != "Himawari-$V.dmg" ]; then
    git switch -q -c "readme-$V"
    sed -i '' "s/$OLD/Himawari-$V.dmg/g; s/Download Himawari Beta [0-9.]* (DMG)/Download Himawari Beta $V (DMG)/" README.md
    git commit -qam "README: Beta $V download"
    git push -q -u origin "readme-$V"
    gh pr create --title "README: Beta $V download" --base main --head "readme-$V" --body "Points the download links at the released Beta $V DMG. Docs only." >/dev/null
    for _ in $(seq 1 60); do gh pr checks "readme-$V" 2>/dev/null | grep -qE "pass|fail" && break; sleep 15; done
    gh pr merge "readme-$V" --squash --delete-branch || echo "README pull request left open: merge it by hand"
fi

# The project page.
if [ -d "$SITE" ]; then
    cd "$SITE" && git pull -q --ff-only
    sed -i '' -E "s/Himawari-[0-9.]+\.dmg/Himawari-$V.dmg/g; s/>BETA [0-9.]+</>BETA $V</" index.html
    # Release-day page changes prepared in the site repo ("Coming in Beta …" → "New in Beta …").
    [ -f "release/$V.sed" ] && sed -i '' -f "release/$V.sed" index.html
    git commit -qam "Beta $V" && git push -q || true
fi

notify "Himawari Beta $V is out."
echo "Released $V"
