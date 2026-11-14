#!/bin/zsh
# GitHub git clones of the binary-heavy dependencies (FFmpegBuild 380 MB, LibDovi)
# crawl at ~90 KB/s from here, while codeload tarballs run at MB/s. This builds
# local tagged git mirrors from tarballs and points SwiftPM (CLI and Xcode) at them.
# Re-run after bumping a dependency version in MezzanineKit/Package.swift.
set -euo pipefail
root=${0:A:h:h}
M=~/Library/Caches/mezzanine-spm-mirrors
mkdir -p $M
typeset -A deps=(
  AetherEngine "superuser404notfound/AetherEngine 7.67.0"
  FFmpegBuild "superuser404notfound/FFmpegBuild 3.15.0"
  LibDovi "superuser404notfound/LibDovi 2.2.0"
  LibTrueHD "superuser404notfound/LibTrueHD 3.2.0"
  GRDB.swift "groue/GRDB.swift v7.12.0"
  SMBClient "kishikawakatsumi/SMBClient 0.3.1"
)
for name spec in ${(kv)deps}; do
  repo=${spec%% *}; tag=${spec##* }
  if ! git -C "$M/$name" rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1; then
    rm -rf "$M/$name"; mkdir -p "$M/$name"
    curl -sSL "https://codeload.github.com/$repo/tar.gz/refs/tags/$tag" | tar xz -C "$M/$name" --strip-components=1
    (cd "$M/$name" && git init -q && git add -A && git -c user.name=mirror -c user.email=mirror@local commit -q -m "mirror $repo $tag" && git tag "$tag")
  fi
  (cd "$root/MezzanineKit" && swift package config set-mirror --original "https://github.com/$repo" --mirror "file://$M/$name")
  echo "$name $tag"
done
D="$root/Mezzanine.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/configuration"
mkdir -p "$D" && cp "$root/MezzanineKit/.swiftpm/configuration/mirrors.json" "$D/"
