// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppleAuth",
    platforms: [.iOS(.v13), .macOS(.v12)],
    products: [.library(name: "AppleAuth", targets: ["AppleAuth"])],
    targets: [
        .binaryTarget(name: "apple_auth", path: "Artifacts/apple_auth.xcframework"),
        .target(name: "AppleAuth", dependencies: ["apple_auth"], linkerSettings: [
            .linkedLibrary("c++"), .linkedLibrary("z"), .linkedFramework("CoreFoundation")
        ])
    ]
)
