#!/bin/zsh
# The pictures in the README and on the website: starts the demo server (Scripts/demo: open films, no
# Plex server), captures each page, frames it into docs/screenshots/. Build Debug first; needs
# Scripts/demo/fetch.py and art.swift once. Takes over the screen for about six minutes.
#   Scripts/screenshots/all.sh [name…]
set -u
here=${0:A:h}; root=${here:h:h}
# Titles are keys in Scripts/demo/library.json, in order from 101.
FILM=101 SHOW=114 QUEUE=102,103,116
typeset -A shots
shots=(
  home            "12"
  unwatched       "12 -SidebarSelect slice:unwatched:1"
  watchlist       "13 -SidebarSelect watchlist"
  show            "12 -MezzanineOpen $SHOW"
  movie           "12 -MezzanineOpen 105"
  search          "12 -SearchQuery sp"
  quickopen       "12 -QuickOpenQuery s"
  player          "15 -MezzanineAutoplay $FILM -MezzanineAutoSeek 300 -PlayerChromePinned YES -ClockAt 21:13 -MezzanineAutoClose 60"
  before          "15 -MezzanineAutoplay $FILM -MezzanineAutoSeek 128 -ClockAt 21:10 -MezzanineAutoClose 60"
  subtitle        "15 -MezzanineAutoplay $FILM -MezzanineAutoSeek 130 -PlayerKeyScript ~7,w -ClockAt 21:10 -MezzanineAutoClose 60"
  credits         "15 -MezzanineAutoplay $FILM -MezzanineAutoSeek 722 -PlayerChromePinned YES -QueueSeed 102,103 -ClockAt 21:20 -MezzanineAutoClose 60"
  player-options  "15 -MezzanineAutoplay $FILM -MezzanineAutoSeek 296 -PlayerOptionsOpen YES -ClockAt 21:13 -MezzanineAutoClose 60"
  queue           "15 -MezzanineAutoplay $FILM -MezzanineAutoSeek 327 -QueueSeed $QUEUE -PlayerOptionsPage queue -ClockAt 21:13 -MezzanineAutoClose 60"
  sleep           "15 -MezzanineAutoplay $FILM -MezzanineAutoSeek 690 -SleepTimerSeconds 850 -PlayerOptionsPage sleep -ClockAt 21:19 -MezzanineAutoClose 60"
  mini            "16 -MezzanineAutoplay $FILM -MezzanineAutoSeek 306 -PlayerKeyScript ~6,opt+m -MezzanineAutoClose 60"
)
# The player in a window closer to the film's shape.
wide=(player subtitle before credits player-options queue sleep)
names=(${@:-home unwatched watchlist show movie search quickopen player before subtitle credits player-options queue sleep mini})
python3 $root/Scripts/demo/server.py 32499 > /dev/null 2>&1 & server=$!
trap "kill $server 2>/dev/null" EXIT
sleep 1
for n in ${=names}; do
  size=1440x900; (( ${wide[(Ie)$n]} )) && size=1440x760
  SIZE=$size $here/capture.sh $n ${=shots[$n]} || exit 1
  [[ $n == (before|mini|quickopen|subtitle) ]] && continue # the website's only
  swift $here/frame.swift $root/build.noindex/shots/$n.png $root/docs/screenshots/$n.jpg
done
