#!/bin/zsh
# CI: removes the signing keychain and key files, whatever happened before.
security delete-keychain "$RUNNER_TEMP/signing.keychain-db" 2>/dev/null || true
command rm -f "$RUNNER_TEMP/sparkle_ed_key" "$RUNNER_TEMP/releases_deploy_key" "$RUNNER_TEMP/identity.p12"
