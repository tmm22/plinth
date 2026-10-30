// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Plinth",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Plinth", targets: ["Plinth"])],
    dependencies: [.package(url: "https://github.com/nicklockwood/Euclid.git", exact: "0.10.0")],
    targets: [
        .executableTarget(name: "Plinth", dependencies: ["Euclid"], resources: [.copy("Resources/openapi.json"), .copy("Resources/slant-openapi-upstream.json"), .copy("Resources/Euclid-LICENSE.txt")]),
        .testTarget(name: "PlinthTests", dependencies: ["Plinth"])
    ],
    swiftLanguageModes: [.v5]
)
