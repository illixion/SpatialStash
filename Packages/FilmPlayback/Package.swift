// swift-tools-version: 6.2
import PackageDescription

// A Hypnos-local package for the film player: the Atmos Objects plugin's
// video segments rendered through AVSampleBufferDisplayLayer on a host-clock
// timebase, so picture and the object audio can share one clock.
//
// A package for the same reason as NextcloudMedia: none of the core needs a
// headset. `./run-lab.sh` opens the player on the Mac, whose display
// shows HDR and Dolby Vision, and iterating there beats a device round trip.
// visionOS and iOS are declared because the app links the library product.
let package = Package(
    name: "FilmPlayback",
    platforms: [.macOS(.v15), .visionOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "FilmPlayback", targets: ["FilmPlayback"]),
    ],
    targets: [
        .target(name: "FilmPlayback"),
        .testTarget(
            name: "FilmPlaybackTests",
            dependencies: ["FilmPlayback"],
            resources: [.copy("Fixtures")]
        ),
        // Mac test bench. Not a product, so the app never builds it. Reads the
        // server and token from the environment so none are committed. An
        // unbundled executable has no Info.plist, so one is embedded in the
        // binary: head tracking needs its NSMotionUsageDescription.
        .executableTarget(
            name: "PlayerLab",
            dependencies: ["FilmPlayback"],
            exclude: ["Info.plist"],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                "-Xlinker", Context.packageDirectory + "/Sources/PlayerLab/Info.plist",
            ])]
        ),
    ]
)
