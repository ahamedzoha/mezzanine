#!/bin/zsh
# Scripts/publish-release.sh: hands build.noindex/dist/ to the public mezzanine-releases repo by
# committing the DMG and release.json under staging/; that repo's Publish workflow turns them into
# a GitHub Release and an appcast entry, then drops them from its history. Does nothing if the
# version is already published.
#   RELEASES_REMOTE  push URL (CI: SSH with the deploy key; default HTTPS with your git login)
set -euo pipefail
root=${0:A:h:h}
dist=${DIST:-$root/build.noindex/dist}
remote=${RELEASES_REMOTE:-https://github.com/ahamedzoha/mezzanine-releases.git}
version=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" "$dist/release.json")
dmg=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['dmg'])" "$dist/release.json")

if git ls-remote --tags "$remote" "refs/tags/v$version" | grep -q .; then
  echo "Mezzanine $version is already published."; exit 0
fi
work=$(mktemp -d)
trap 'command rm -rf "$work"' EXIT
git clone --quiet --depth 1 "$remote" "$work/repo"
mkdir -p "$work/repo/staging"
cp "$dist/$dmg" "$dist/release.json" "$dist/notes.md" "$work/repo/staging/"
cd "$work/repo"
git add staging
# The owner's name with their GitHub no-reply address: this repo is public.
git -c user.name="ahamedzoha" -c user.email="13367662+ahamedzoha@users.noreply.github.com" \
  commit --quiet -m "Stage Mezzanine $version"
git push --quiet origin HEAD:main
echo "Staged Mezzanine $version; the releases repo publishes it in a minute or two."
