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
        .target(name: "DFMCore", dependencies: ["CArchive"]),
        .executableTarget(name: "DFileManager", dependencies: ["DFMCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .executableTarget(name: "bench", dependencies: ["DFMCore"]),
        .testTarget(name: "DFMCoreTests", dependencies: ["DFMCore"]),
        .testTarget(name: "DFileManagerTests", dependencies: ["DFileManager"]),
    ]
)
