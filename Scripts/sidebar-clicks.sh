#!/bin/zsh
# Scripts/sidebar-clicks.sh [steps] [rounds]: clicks sidebar rows in the Debug build with real mouse
# events (-PageCycle) while its window is key, then says whether the app survived. Build Debug first.
# It brings the window to the front for a few seconds. Rows count section headers: with three
# Continue titles, 0 Home, 1 Watchlist, 3 a Continue title, 7 Movies, 8 Movies ▸ Unwatched, 12 TV Shows.
#   Scripts/sidebar-clicks.sh                              # Movies ↔ Home, three rounds
#   Scripts/sidebar-clicks.sh "row:7,row:0,row:3,row:12" 2
# Regression check for the macOS 27.2 toolbar crash: a click that changed the page inside the
# outline view's mouse handling made NSToolbarItemViewer throw (Sidebar.deferredSelection).
steps=${1:-row:7,row:0}; rounds=${2:-3}
root=~/Code/mezzanine
bin=$root/build.noindex/DerivedData/Build/Products/Debug/Mezzanine.app/Contents/MacOS/Mezzanine
out=$root/build.noindex/ui; mkdir -p $out; log=$out/sidebar-clicks.log
source $root/.mezzanine-live.env
MEZZANINE_DEV_TOKEN="$PLEX_TOKEN" script -q /dev/null $bin -MezzanineNoActivity YES -ApplePersistenceIgnoreState YES \
  -onboardingComplete YES -lastSidebarItem home -PageCycle "activate,$steps" -PageCycleCount $rounds -PageCycleMs 900 \
  < /dev/null > $log 2>&1 &
# Clicks only land in the key window, and a shell-launched app isn't activated on its own.
for i in {1..150}; do
  sleep 1
  grep -qa "PAGE 0" $log || osascript -e 'tell application id "com.mezzanine.mac.debug" to activate' >/dev/null 2>&1
  grep -qa "PAGE done" $log && break
  pgrep -f "$bin" >/dev/null || break
done
sleep 2
tr -d '\r' < $log | grep -E "^PAGE|ROW" | tail -$(( ${#${(s:,:)steps}} * rounds + 2 ))
grep -qa "key=false" $log && echo "warning: the window wasn't key for every step (clicks need it)"
if ! grep -qa "PAGE done" $log && pgrep -f "$bin" >/dev/null; then
  echo "timed out (still running)"; osascript -e 'tell application id "com.mezzanine.mac.debug" to quit' >/dev/null 2>&1; exit 2
elif ! grep -qa "PAGE done" $log; then
  echo "CRASHED (the app quit before the last step; report in ~/Library/Logs/DiagnosticReports)"; exit 1
fi
osascript -e 'tell application id "com.mezzanine.mac.debug" to quit' >/dev/null 2>&1
echo "survived"
