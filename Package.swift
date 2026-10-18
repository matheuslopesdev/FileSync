// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FileSync",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "FileSync", path: "Sources/FileSync")
    ],
    swiftLanguageModes: [.v5]
)
