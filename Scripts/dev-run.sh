#!/bin/zsh
# Builds Debug and runs Mezzanine from the shell with the dev token seeded
# (first launch only; it then lives in the Keychain) and activity reporting off.
#   Scripts/dev-run.sh                      # just run
#   Scripts/dev-run.sh -LabAutoMatrix YES   # scripted S2 matrix, results on stdout
set -euo pipefail
root=${0:A:h:h}
xcodebuild -project "$root/Mezzanine.xcodeproj" -scheme Mezzanine -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$root/build.noindex/DerivedData" build -quiet
app="$root/build.noindex/DerivedData/Build/Products/Debug/Mezzanine.app"
source "$root/.mezzanine-live.env"
MEZZANINE_DEV_TOKEN="$PLEX_TOKEN" exec "$app/Contents/MacOS/Mezzanine" \
  -MezzanineNoActivity YES -ApplePersistenceIgnoreState YES "$@"
