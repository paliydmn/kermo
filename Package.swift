// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dfilemanager",
    platforms: [.macOS(.v14)],
    dependencies: [
        // 1.12+ ships Metal shaders, which need Xcode's `metal` compiler; 1.11 builds with Command Line Tools.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", .upToNextMinor(from: "1.11.2")),
    ],
    targets: [
        .systemLibrary(name: "CArchive", path: "Sources/CArchive"),
        .target(name: "DFMCore", dependencies: ["CArchive"], resources: [.copy("Resources/tools")]),   // the built-in Tools presets
        .executableTarget(name: "DFileManager", dependencies: ["DFMCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .executableTarget(name: "bench", dependencies: ["DFMCore"]),
        .executableTarget(name: "tools-lint", dependencies: ["DFMCore"]),   // checks presets: for editors and the catalog's CI
        .testTarget(name: "DFMCoreTests", dependencies: ["DFMCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "DFileManagerTests", dependencies: ["DFileManager"]),
    ]
)
