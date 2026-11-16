# Third-party notices

Mezzanine's own source is under the [MIT license](LICENSE). The app bundles these components;
each keeps its own license. Their full license texts ship inside each framework in
`Mezzanine.app/Contents/Frameworks` and are in the linked repositories.

| Component | What it does in Mezzanine | License |
|---|---|---|
| [AetherEngine](https://github.com/superuser404notfound/AetherEngine) | Playback: demuxing, decoding, HLS to AVPlayer, audio shaping | LGPL-3.0 with an app store / DRM exception |
| [FFmpegBuild](https://github.com/superuser404notfound/FFmpegBuild): FFmpeg libraries (avcodec, avformat, avutil, avfilter, swresample, swscale) | Used by AetherEngine | LGPL-2.1 or later (built without GPL components) |
| dav1d (in FFmpegBuild) | AV1 decoding | BSD-2-Clause |
| zimg (in FFmpegBuild) | Scaling and colour conversion | WTFPL |
| libzvbi (in FFmpegBuild) | Teletext subtitles | LGPL-2.1 or later (GPL parts excluded) |
| [LibDovi](https://github.com/superuser404notfound/LibDovi) (libdovi from dovi_tool) | Dolby Vision metadata | MIT |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | The local library index (SQLite) | MIT |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | Software updates | MIT |

## LGPL components

AetherEngine and the FFmpeg libraries are dynamically linked frameworks, kept as separate files
inside the app bundle. You may replace them with your own builds of the same versions (the exact
versions are pinned in `Mezzanine.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`),
and the complete corresponding source is available from the repositories above. Building Mezzanine
from this repository against modified copies of those packages is supported: point the Swift
package references at your forks.

## Trademarks

Plex is a trademark of Plex, Inc. Google Cast is a trademark of Google LLC. AirPlay is a trademark
of Apple Inc. Mezzanine is independent and not affiliated with or endorsed by any of them.
