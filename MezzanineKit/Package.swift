// swift-tools-version: 6.2
import PackageDescription

// MezzanineKit holds everything that doesn't touch the UI: the Plex client
// (plex.tv auth, discovery, server API), models, URL building, the local
// library index and parsers. Package default is non-isolated code, so
// decoding and indexing run off the main actor; the app target is
// MainActor-by-default.
//
// MezzaninePlayback holds `MezzaninePlayer`, the only code that imports AetherEngine; the app
// talks to Mezzanine's own types, so engine API churn (it releases almost daily) touches one
// file. AetherEngine is pinned to an exact version on purpose: bump it deliberately and re-run
// the playback matrix.
let package = Package(
    name: "MezzanineKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MezzanineKit", targets: ["MezzanineKit"]),
        .library(name: "MezzaninePlayback", targets: ["MezzaninePlayback"]),
    ],
    dependencies: [
        .package(url: "https://github.com/superuser404notfound/AetherEngine", exact: "7.67.0"),
        .package(url: "https://github.com/groue/GRDB.swift", .upToNextMinor(from: "7.12.0")),
    ],
    targets: [
        .target(
            name: "MezzanineKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "MezzaninePlayback",
            dependencies: [
                "MezzanineKit",
                .product(name: "AetherEngine", package: "AetherEngine"),
            ]
        ),
        .testTarget(
            name: "MezzanineKitTests",
            dependencies: ["MezzanineKit"],
            resources: [.copy("Fixtures")]
        ),
        // Talks to the real server. Skipped unless MEZZANINE_LIVE=1 (Scripts/live-test.sh).
        .testTarget(name: "MezzanineLiveTests", dependencies: ["MezzanineKit"]),
    ]
)
