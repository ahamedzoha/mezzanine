#!/bin/zsh
# CI: publishes build.noindex/dist/ through the releases repo's deploy key (RELEASES_DEPLOY_KEY),
# which can write to ahamedzoha/mezzanine-releases and nothing else.
set -euo pipefail
key="$RUNNER_TEMP/releases_deploy_key"
printf '%s\n' "$RELEASES_DEPLOY_KEY" > "$key"
chmod 600 "$key"
# GitHub's published SSH host keys, fetched over HTTPS (no trust-on-first-use).
curl -fsSL https://api.github.com/meta | python3 -c "
import json, sys
for k in json.load(sys.stdin)['ssh_keys']: print('github.com', k)" > "$RUNNER_TEMP/known_hosts"
export GIT_SSH_COMMAND="ssh -i $key -o IdentitiesOnly=yes -o UserKnownHostsFile=$RUNNER_TEMP/known_hosts -o StrictHostKeyChecking=yes"
RELEASES_REMOTE=git@github.com:ahamedzoha/mezzanine-releases.git Scripts/publish-release.sh
