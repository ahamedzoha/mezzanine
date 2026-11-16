#!/bin/zsh
# Scripts/github-release.sh: creates (or refreshes) the GitHub Release for the version in
# build.noindex/dist/ on this repo, with the DMG and the CHANGELOG notes. The Sparkle feed stays in
# ahamedzoha/mezzanine-releases; this is the page people download from. Uses gh's login locally and
# GITHUB_TOKEN (GH_TOKEN) in CI.
set -euo pipefail
root=${0:A:h:h}
dist=${DIST:-$root/build.noindex/dist}
repo=${GITHUB_REPOSITORY:-ahamedzoha/mezzanine}
version=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" "$dist/release.json")
dmg=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['dmg'])" "$dist/release.json")
notes=$(mktemp)
{ cat "$dist/notes.md"; printf '\n\nRequires macOS 26 on Apple silicon. Installed copies update themselves.\n'; } > "$notes"
if gh release view "v$version" --repo "$repo" > /dev/null 2>&1; then
  gh release upload "v$version" "$dist/$dmg" --repo "$repo" --clobber
  gh release edit "v$version" --repo "$repo" --notes-file "$notes"
else
  gh release create "v$version" "$dist/$dmg" --repo "$repo" --verify-tag --title "Mezzanine $version" \
    --notes-file "$notes" --latest
fi
command rm -f "$notes"
echo "GitHub Release: https://github.com/$repo/releases/tag/v$version"
