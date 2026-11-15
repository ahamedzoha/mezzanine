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
