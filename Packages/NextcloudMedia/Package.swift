// swift-tools-version: 6.2
import PackageDescription

// A Hypnos-local package, deliberately not part of RAVESDK: nothing here is
// shared with the other RAVE apps, and RAVESDK's scope is the code that is.
//
// It is a package rather than app-target sources for one reason — none of this
// touches visionOS, so it builds and tests natively on the host in about two
// seconds. Iterating on DAV request shapes, XML parsing and paging against
// `swift test` beats a simulator round trip by an order of magnitude, and the
// live bench (`swift run ncbench`) can hit a real server without a device.
//
// macOS is therefore a first-class platform here, not an afterthought; visionOS,
// iOS and tvOS are declared because the app links the library product on each
// (tvOS added 2026-09-24 for Hypnos on Apple TV — an undeclared platform gets
// SwiftPM's ancient default deployment floor, not an excluded one).
let package = Package(
    name: "NextcloudMedia",
    platforms: [.macOS(.v14), .visionOS(.v26), .iOS(.v26), .tvOS(.v26)],
    products: [
        .library(name: "NextcloudMedia", targets: ["NextcloudMedia"]),
    ],
    targets: [
        .target(name: "NextcloudMedia"),
        .testTarget(name: "NextcloudMediaTests", dependencies: ["NextcloudMedia"]),
        // Live bench. Not a product, so the app never builds it; reads its
        // credentials from the environment so none are committed.
        .executableTarget(name: "ncbench", dependencies: ["NextcloudMedia"]),
    ]
)
