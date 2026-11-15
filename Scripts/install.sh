#!/bin/zsh
# Builds Mezzanine (Release, signed with the Apple Development identity) and
# installs it into /Applications, replacing any previous copy: a quick local
# install (Scripts/release.sh ships a version that updates itself everywhere).
# The Plex token stays in the Keychain and settings in the sandbox container,
# so an update keeps everything.
set -euo pipefail
root=${0:A:h:h}
derived="$root/build.noindex/ReleaseData"
app="$derived/Build/Products/Release/Mezzanine.app"

echo "Building Mezzanine (Release)…"
# The build number is the commit count, as in published releases, so Sparkle compares a local
# install correctly with what's out.
xcodebuild -project "$root/Mezzanine.xcodeproj" -scheme Mezzanine -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$derived" \
  CURRENT_PROJECT_VERSION="$(git -C "$root" rev-list --count HEAD)" build -quiet

"$root/Scripts/sign-sparkle.sh" "$app"
version=$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString)

if pgrep -xq Mezzanine; then
  echo "Quitting the running Mezzanine…"
  osascript -e 'tell application "Mezzanine" to quit' || true
  for _ in {1..20}; do pgrep -xq Mezzanine || break; sleep 0.25; done
fi

ditto "$app" /Applications/Mezzanine.app.new
command rm -rf /Applications/Mezzanine.app
mv /Applications/Mezzanine.app.new /Applications/Mezzanine.app
echo "Installed Mezzanine $version in /Applications."
