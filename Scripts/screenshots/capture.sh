#!/bin/zsh
# Scripts/screenshots/capture.sh <name> <wait-s> <app args…>: runs the Debug build against the demo
# library (open films on 127.0.0.1, Scripts/demo; plex.tv and real servers are never asked), muted,
# sizes the window to 1440×900 and captures that window alone into build.noindex/shots/<name>.png.
# Scripts/screenshots/all.sh makes the set. SIZE=… changes the window.
name=$1; wait=$2; shift 2
root=${0:A:h:h:h}
bin=$root/build.noindex/DerivedData/Build/Products/Debug/Mezzanine.app/Contents/MacOS/Mezzanine
curl -sf -o /dev/null http://127.0.0.1:32499/identity || { echo "Start Scripts/demo/server.py first." >&2; exit 1; }
shots=$root/build.noindex/shots; mkdir -p $shots
[[ -x $shots/window ]] || swiftc -O -o $shots/window $root/Scripts/screenshots/window.swift
$bin -DemoServer http://127.0.0.1:32499 -MezzanineNoActivity YES -onboardingComplete YES -ApplePersistenceIgnoreState YES \
  -PublicNames YES -playerMuted YES -AppleLocale en_GB -WindowSize ${SIZE:-1440x900} "$@" > $shots/$name.log 2>&1 &
pid=$!
sleep $wait
osascript -e 'tell application id "com.mezzanine.mac.debug" to activate' >/dev/null 2>&1
sleep ${SETTLE:-1.5}
id=$($shots/window $pid) && screencapture -x -o -l $id $shots/$name.png && echo "$name $(sips -g pixelWidth -g pixelHeight $shots/$name.png | awk '/pixel/{print $2}' | paste -sd x -)"
osascript -e 'tell application id "com.mezzanine.mac.debug" to quit' >/dev/null 2>&1
sleep 2
