# Security

Please report vulnerabilities privately through
[GitHub's private vulnerability reporting](https://github.com/ahamedzoha/mezzanine/security/advisories/new),
not in a public issue. Include what you found, how to reproduce it, and what it could expose.
You'll get a reply within a week.

Things that matter most here: anything that could leak a Plex token (they belong in the Keychain
and in request headers only), anything that lets a server or subtitle site run code or read files
outside the app's sandbox, and the update path (updates must carry Mezzanine's EdDSA signature).

Only the latest release gets fixes.
