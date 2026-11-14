#!/bin/zsh
# Read-only tests against the real Plex server. Loads the dev token from
# .mezzanine-live.env (mode 600, gitignored) into the environment only.
set -euo pipefail
root=${0:A:h:h}
set -a; source "$root/.mezzanine-live.env"; set +a
cd "$root/MezzanineKit"
MEZZANINE_LIVE=1 swift test --filter MezzanineLiveTests "$@"
