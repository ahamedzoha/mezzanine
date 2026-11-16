#!/bin/zsh
# Scripts/screenshots/capture.sh <name> <wait-s> <app args…>: runs the Debug build (no activity
# reported), sizes the window to 1440×900, and captures just the window into
# build.noindex/shots/<name>.png. Then: swift Scripts/screenshots/frame.swift in.png out.jpg [blur]
# (blur hides the profile row). The README's set:
#   capture.sh home 9 -lastSidebarItem home
#   capture.sh show 10 -MezzanineSection "TV Shows" -MezzanineOpen <show ratingKey>
#   capture.sh movie 9 -MezzanineOpen <film ratingKey>
#   capture.sh library 9 -MezzanineSection Movies
#   capture.sh search 11 -lastSidebarItem home -SearchQuery "the"
#   capture.sh player 15 -MezzanineAutoplay <film> -MezzanineAutoSeek <s> -PlayerChromePinned YES -MezzanineAutoClose 40
#   capture.sh player-options 15 -MezzanineAutoplay <film> -MezzanineAutoSeek <s> -PlayerOptionsOpen YES -MezzanineAutoClose 40
name=$1; wait=$2; shift 2
root=${0:A:h:h:h}
bin=$root/build.noindex/DerivedData/Build/Products/Debug/Mezzanine.app/Contents/MacOS/Mezzanine
source $root/.mezzanine-live.env
mkdir -p $root/build.noindex/shots
MEZZANINE_DEV_TOKEN="$PLEX_TOKEN" $bin -MezzanineNoActivity YES -onboardingComplete YES "$@" > $root/build.noindex/shots/$name.log 2>&1 &
sleep $wait
osascript -e 'tell application id "com.mezzanine.mac.debug" to activate' >/dev/null 2>&1
osascript -e 'tell application "System Events" to tell (first process whose bundle identifier is "com.mezzanine.mac.debug")' \
  -e 'set position of window 1 to {560, 250}' -e 'set size of window 1 to {1440, 900}' -e 'end tell' >/dev/null 2>&1
sleep ${SETTLE:-2.5}
b=$(osascript -e 'tell application "System Events" to tell (first process whose bundle identifier is "com.mezzanine.mac.debug") to get {position, size} of window 1' 2>/dev/null | tr -d ' ')
screencapture -x -R "$b" $root/build.noindex/shots/$name.png
echo "$name bounds=$b"
osascript -e 'tell application id "com.mezzanine.mac.debug" to quit' >/dev/null 2>&1
sleep 2
