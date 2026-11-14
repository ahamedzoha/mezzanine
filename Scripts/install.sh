#!/bin/zsh
# Builds Mezzanine (Release, signed with the Apple Development identity) and
# installs it into /Applications, replacing any previous copy. The Plex token
# stays in the Keychain and settings in the sandbox container, so an update
# keeps everything.
set -euo pipefail
root=${0:A:h:h}
derived="$root/build.noindex/ReleaseData"
app="$derived/Build/Products/Release/Mezzanine.app"

echo "Building Mezzanine (Release)…"
xcodebuild -project "$root/Mezzanine.xcodeproj" -scheme Mezzanine -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$derived" build -quiet

codesign --verify --strict "$app"
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
