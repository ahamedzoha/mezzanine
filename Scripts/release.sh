#!/bin/zsh
# Scripts/release.sh <version> [--local]: ships a version of Mezzanine.
#   1. CHANGELOG.md needs a "## <version>" section: it's what the update window shows.
#   2. Sets the app's MARKETING_VERSION, commits "Release <version>" and tags v<version>.
#   3. Pushes main and the tag. CI (on the tag) tests, builds, signs, makes the DMG and
#      publishes to ahamedzoha/mezzanine-releases; installed copies then update themselves.
# --local builds and publishes from this Mac instead (no CI minutes), waits until the releases
# repo has published it, then pushes; CI sees the version is out and stops early.
set -euo pipefail
root=${0:A:h:h}
cd "$root"
version=${1:?usage: Scripts/release.sh <version> [--local]}
here=false; [[ ${2:-} == --local ]] && here=true

[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Version looks like 0.3.0." >&2; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "Commit or stash your changes first." >&2; exit 1; }
[[ $(git branch --show-current) == main ]] || { echo "Release from main." >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/v$version" > /dev/null; then echo "v$version already exists." >&2; exit 1; fi
python3 Scripts/release-notes.py "$version" > /dev/null

# The app target's two configurations (Debug, Release); the test target keeps its own.
python3 - "$version" <<'PY'
import re, sys
p = "Mezzanine.xcodeproj/project.pbxproj"
s = open(p).read()
def bump(block):
    b = block.group(0)
    if re.search(r"PRODUCT_BUNDLE_IDENTIFIER = com\.mezzanine\.mac(\.debug)?;", b):
        b = re.sub(r"MARKETING_VERSION = [^;]+;", f"MARKETING_VERSION = {sys.argv[1]};", b)
    return b
open(p, "w").write(re.sub(r"buildSettings = \{.*?\n\t\t\t\};", bump, s, flags=re.S))
PY
git add Mezzanine.xcodeproj/project.pbxproj
git diff --cached --quiet || git commit --quiet -m "Release $version"
git tag -a "v$version" -m "Mezzanine $version"

if $here; then
  Scripts/build-release.sh
  Scripts/publish-release.sh
  echo "Waiting for the releases repo to publish $version…"
  for _ in {1..60}; do
    git ls-remote --tags https://github.com/ahamedzoha/mezzanine-releases.git "refs/tags/v$version" | grep -q . && break
    sleep 5
  done
  git ls-remote --tags https://github.com/ahamedzoha/mezzanine-releases.git "refs/tags/v$version" | grep -q . \
    || { echo "Not published after 5 minutes: check the Publish workflow in mezzanine-releases." >&2; exit 1; }
fi
git push --quiet origin main
git push --quiet origin "v$version"
if $here; then
  echo "Mezzanine $version is out: https://github.com/ahamedzoha/mezzanine-releases/releases/tag/v$version"
else
  echo "Tagged v$version; CI builds and publishes it: gh run watch \$(gh run list -w Release -L 1 --json databaseId -q '.[0].databaseId')"
fi
