#!/bin/zsh
# CI: puts the Apple Development identity (MAC_CERT_P12, base64 .p12, and MAC_CERT_PASSWORD)
# into a throwaway keychain that codesign can use without prompts. Scripts/ci/cleanup.sh deletes it.
set -euo pipefail
kc="$RUNNER_TEMP/signing.keychain-db"
pw=$(uuidgen)
security create-keychain -p "$pw" "$kc"
security set-keychain-settings -lut 21600 "$kc"
security unlock-keychain -p "$pw" "$kc"
printf '%s' "$MAC_CERT_P12" | base64 --decode > "$RUNNER_TEMP/identity.p12"
security import "$RUNNER_TEMP/identity.p12" -k "$kc" -P "$MAC_CERT_PASSWORD" -f pkcs12 -T /usr/bin/codesign -T /usr/bin/security > /dev/null
command rm -f "$RUNNER_TEMP/identity.p12"
# The intermediate that issued the certificate (Apple WWDR G3), so the chain verifies.
curl -fsSL https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer -o "$RUNNER_TEMP/wwdr.cer"
security import "$RUNNER_TEMP/wwdr.cer" -k "$kc" > /dev/null 2>&1 || true
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pw" "$kc" > /dev/null
security list-keychains -d user -s "$kc" $(security list-keychains -d user | tr -d '"')
security find-identity -v -p codesigning "$kc" | tail -1
