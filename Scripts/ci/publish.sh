#!/bin/zsh
# CI: publishes build.noindex/dist/ through the releases repo's deploy key (RELEASES_DEPLOY_KEY),
# which can write to ahamedzoha/mezzanine-releases and nothing else.
set -euo pipefail
key="$RUNNER_TEMP/releases_deploy_key"
printf '%s\n' "$RELEASES_DEPLOY_KEY" > "$key"
chmod 600 "$key"
# GitHub's published ed25519 host key (SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU, from
# api.github.com/meta), pinned: no trust-on-first-use, and the unauthenticated meta API is
# rate-limited on shared runners.
print -r -- "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl" > "$RUNNER_TEMP/known_hosts"
export GIT_SSH_COMMAND="ssh -i $key -o IdentitiesOnly=yes -o UserKnownHostsFile=$RUNNER_TEMP/known_hosts -o StrictHostKeyChecking=yes -o HostKeyAlgorithms=ssh-ed25519"
RELEASES_REMOTE=git@github.com:ahamedzoha/mezzanine-releases.git Scripts/publish-release.sh
