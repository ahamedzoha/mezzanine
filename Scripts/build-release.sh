#!/bin/zsh
# Scripts/build-release.sh: a signed Release of Mezzanine, its installer DMG, and the DMG's
# Sparkle signature, into build.noindex/dist/ (Mezzanine-<version>.dmg, release.json, notes.md).
# Used by CI on a version tag and by `Scripts/release.sh --local`.
#   IDENTITY          codesign identity (default "Apple Development")
#   SPARKLE_KEY_FILE  EdDSA private key file (CI); otherwise the Keychain account "mezzanine"
#   DERIVED, DIST, VENV  build, output and dmgbuild venv folders (defaults under build.noindex)
# The build number is the commit count, so every release is newer than the last.
set -euo pipefail
root=${0:A:h:h}
cd "$root"
identity=${IDENTITY:-"Apple Development"}
derived=${DERIVED:-$root/build.noindex/ReleaseData}
dist=${DIST:-$root/build.noindex/dist}
venv=${VENV:-$root/build.noindex/venv}
build=$(git rev-list --count HEAD)
app="$derived/Build/Products/Release/Mezzanine.app"

echo "Building Mezzanine (Release, build $build)…"
xcodebuild -project Mezzanine.xcodeproj -scheme Mezzanine -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$derived" \
  CURRENT_PROJECT_VERSION="$build" build -quiet
Scripts/sign-sparkle.sh "$app" "$identity"

version=$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString)
if [[ ${GITHUB_REF_TYPE:-} == tag && ${GITHUB_REF_NAME:-} != "v$version" ]]; then
  echo "Tag $GITHUB_REF_NAME doesn't match the app's version $version." >&2; exit 1
fi
notes_md=$(python3 Scripts/release-notes.py "$version")
notes_html=$(python3 Scripts/release-notes.py "$version" --html)

echo "Making the installer DMG…"
if [[ ! -x "$venv/bin/dmgbuild" ]]; then
  python3 -m venv "$venv"
  "$venv/bin/pip" install --quiet --disable-pip-version-check --require-hashes -r Scripts/dmg/requirements.txt
fi
command rm -rf "$dist"; mkdir -p "$dist"
dmg="$dist/Mezzanine-$version.dmg"
"$venv/bin/dmgbuild" -s Scripts/dmg/settings.py -D app="$app" -D background="$root/Scripts/dmg/background.tiff" \
  "Mezzanine" "$dmg" > /dev/null
size=$(stat -f %z "$dmg")
(( size < 95 * 1024 * 1024 )) || { echo "DMG is $size bytes: too big for the releases repo." >&2; exit 1; }

echo "Signing the update…"
sign_update="$derived/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
if [[ -n ${SPARKLE_KEY_FILE:-} ]]; then
  signature=$("$sign_update" --ed-key-file "$SPARKLE_KEY_FILE" -p "$dmg")
else
  signature=$("$sign_update" --account mezzanine -p "$dmg")
fi

print -r -- "$notes_md" > "$dist/notes.md"
VERSION=$version BUILD=$build SIZE=$size SIGNATURE=$signature NOTES_HTML=$notes_html \
COMMIT=$(git rev-parse HEAD) DMG=${dmg:t} python3 - "$dist/release.json" <<'PY'
import json, os, sys
from email.utils import formatdate
json.dump({
    "version": os.environ["VERSION"], "build": os.environ["BUILD"], "dmg": os.environ["DMG"],
    "length": int(os.environ["SIZE"]), "edSignature": os.environ["SIGNATURE"],
    "minimumSystemVersion": "26.0", "notesHTML": os.environ["NOTES_HTML"],
    "pubDate": formatdate(usegmt=True), "commit": os.environ["COMMIT"],
}, open(sys.argv[1], "w"), indent=2)
PY
echo "Built Mezzanine $version ($build): $dmg ($(( size / 1024 / 1024 )) MB)"
