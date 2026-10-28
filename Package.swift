// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SlantStudio",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SlantStudio", targets: ["SlantStudio"])],
    dependencies: [.package(url: "https://github.com/nicklockwood/Euclid.git", exact: "0.10.0")],
    targets: [
        .executableTarget(name: "SlantStudio", dependencies: ["Euclid"], resources: [.copy("Resources/openapi.json"), .copy("Resources/slant-openapi-upstream.json"), .copy("Resources/Euclid-LICENSE.txt")]),
        .testTarget(name: "SlantStudioTests", dependencies: ["SlantStudio"])
    ],
    swiftLanguageModes: [.v5]
)
