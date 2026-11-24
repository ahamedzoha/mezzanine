#!/bin/zsh
# Scripts/sign-sparkle.sh <Mezzanine.app> [identity]: re-signs Sparkle's helpers (installer and
# downloader XPC services, Autoupdate, Updater.app) with our identity, then the framework and the
# app (keeping its entitlements). Xcode leaves the helpers with Sparkle's ad-hoc signatures, and
# a sandboxed app's installer service must carry its own team's signature.
set -euo pipefail
app=$1
identity=${2:-${IDENTITY:-"Apple Development"}}
fw="$app/Contents/Frameworks/Sparkle.framework"
v="$fw/Versions/B"
sign() { codesign --force --sign "$identity" --options runtime "$@" }
sign "$v/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$v/XPCServices/Downloader.xpc"
sign "$v/Autoupdate"
sign "$v/Updater.app"
sign "$fw"
sign --preserve-metadata=entitlements,requirements,flags "$app"
codesign --verify --deep --strict "$app"

# get-task-allow lets any process of the same user attach and read the app's memory (the Plex token
# included). Xcode adds it for Apple Development signing unless CODE_SIGN_INJECT_BASE_ENTITLEMENTS is NO.
while IFS= read -r code; do
  if codesign -d --entitlements - --xml "$code" 2>/dev/null | grep -q get-task-allow; then
    echo "$code carries get-task-allow: not a release build." >&2; exit 1
  fi
done < <(print -rl -- "$app" "$v/XPCServices/Installer.xpc" "$v/XPCServices/Downloader.xpc" "$v/Autoupdate" "$v/Updater.app" "$fw")
