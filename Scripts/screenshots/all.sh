#!/bin/zsh
# The README's screenshots: captures each page and frames it into docs/screenshots/. Build Debug
# first. Takes over the screen for about four minutes. Titles are this server's rating keys:
#   FILM=63481 SHOW=11998 EPISODE=58528 AT=3900 Scripts/screenshots/all.sh [name…]
set -u
here=${0:A:h}; root=${here:h:h}
: ${FILM:=63481} ${SHOW:=58207} ${EPISODE:=61906} ${AT:=3900} ${EPISODE_AT:=1500} ${QUEUE:=58528,57206,54686} ${MOVIES:=1} ${TV:=2}
typeset -A shots
shots=(
  home            "10"
  unwatched       "12 -SidebarSelect slice:unwatched:$MOVIES"
  collections     "13 -SidebarSelect slice:collections:$TV"
  watchlist       "13 -SidebarSelect watchlist"
  show            "12 -MezzanineOpen $SHOW"
  movie           "11 -MezzanineOpen $FILM"
  search          "12 -SearchQuery the"
  player          "18 -MezzanineAutoplay $EPISODE -MezzanineAutoSeek $EPISODE_AT -PlayerChromePinned YES -MezzanineAutoClose 60"
  player-options  "18 -MezzanineAutoplay $FILM -MezzanineAutoSeek $AT -PlayerOptionsOpen YES -MezzanineAutoClose 60"
  queue           "18 -MezzanineAutoplay $FILM -MezzanineAutoSeek $AT -QueueSeed $QUEUE -PlayerOptionsPage queue -MezzanineAutoClose 60"
  sleep           "18 -MezzanineAutoplay $EPISODE -MezzanineAutoSeek $EPISODE_AT -SleepTimerSeconds 2700 -PlayerOptionsPage sleep -MezzanineAutoClose 60"
)
names=(${@:-home unwatched collections watchlist show movie search player player-options queue sleep})
for n in ${=names}; do
  $here/capture.sh $n ${=shots[$n]} || exit 1
  swift $here/frame.swift $root/build.noindex/shots/$n.png $root/docs/screenshots/$n.jpg
done
