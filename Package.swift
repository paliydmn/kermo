// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dfilemanager",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Exact: the terminal leans on its internals (the delegate's defaults, LocalProcess's lifecycle). Its Metal
        // shaders compile at run time, so Command Line Tools build it; Kermo draws with Core Graphics.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.3"),
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
