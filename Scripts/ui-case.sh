#!/bin/zsh
# Scripts/ui-case.sh <name> <capture-after-s> <args…>: runs the Debug build (no activity, state
# restoration on), brings it to the front, captures every display into build.noindex/ui/, quits,
# and prints the DEBUG markers (SEARCHPANEL, QUICKOPEN…). Build Debug first. It takes over the
# screen for a few seconds. Regression cases (see CLAUDE.md):
#   Scripts/ui-case.sh detail-search 13 -MezzanineOpen 11998 -SearchQuery alien
#   Scripts/ui-case.sh detail-quickopen 13 -MezzanineOpen 11998 -QuickOpenQuery arch
#   Scripts/ui-case.sh detail-season 14 -MezzanineOpen 58207 -DetailSeason 3 -DetailSection episodes
#     (Breaking Bad opens on S5 and then switches; rows must read 1. No Más, 2. Caballo sin Nombre)
name=$1; wait=$2; shift 2
root=~/Code/mezzanine
bin=$root/build.noindex/DerivedData/Build/Products/Debug/Mezzanine.app/Contents/MacOS/Mezzanine
out=$root/build.noindex/ui; mkdir -p $out
source $root/.mezzanine-live.env
# Each case starts on Home unless it names a section (the last run's section would come back).
home=(-lastSidebarItem home); [[ " $* " == *" -lastSidebarItem "* || " $* " == *" -MezzanineSection "* ]] && home=()
MEZZANINE_DEV_TOKEN="$PLEX_TOKEN" script -q /dev/null $bin -MezzanineNoActivity YES -onboardingComplete YES $home "$@" < /dev/null > $out/$name.log 2>&1 &
sleep $wait
osascript -e 'tell application id "com.mezzanine.mac.debug" to activate' >/dev/null 2>&1
sleep 1.2
screencapture -x $out/$name-1.png $out/$name-2.png $out/$name-3.png 2>/dev/null
osascript -e 'tell application id "com.mezzanine.mac.debug" to quit' >/dev/null 2>&1
sleep 2
tr -d '\r' < $out/$name.log | grep -E "SEARCHPANEL|QUICKOPEN|FOLDERS|DETAIL|MINI|PERF home|SIDEBAR|SLEEP|CATCHUP|DIAGNOSTICS|AUTOPLAY|error|Fatal" | head -24
