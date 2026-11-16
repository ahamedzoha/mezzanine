#!/bin/zsh
# Read-only Plex API helper for development. Loads the dev token from
# .mezzanine-live.env (mode 600, gitignored) and never prints it.
#   Scripts/plex.sh tv /api/v2/resources?includeHttps=1   (plex.tv)
#   Scripts/plex.sh pms /library/sections                  (the server: PLEX_SERVER in the env file)
# Only GET is allowed here: writes go through the app, with -MezzanineNoActivity in tests.
set -euo pipefail
root=${0:A:h:h}
source "$root/.mezzanine-live.env"
target=$1; endpoint=$2
case $target in
  tv)  base="https://plex.tv" ;;
  pms) base="${PLEX_SERVER:?set PLEX_SERVER (the server URL) in .mezzanine-live.env}" ;;
  *) echo "usage: plex.sh tv|pms PATH" >&2; exit 2 ;;
esac
token="$PLEX_TOKEN"
[[ $target == pms && -n "${PLEX_SERVER_TOKEN:-}" ]] && token="$PLEX_SERVER_TOKEN"
curl -sS --fail-with-body -G "$base$endpoint" \
  -H "Accept: application/json" \
  -H "X-Plex-Product: Mezzanine (dev)" \
  -H "X-Plex-Client-Identifier: $PLEX_CLIENT_ID" \
  -H "X-Plex-Token: $token"
