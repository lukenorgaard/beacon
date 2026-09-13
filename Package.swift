// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Beacon",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Beacon", targets: ["Lookout"])],
    targets: [
        .executableTarget(
            name: "Lookout",
            path: "Sources/Lookout"
        ),
        // The repository already had a lowercase `tests/` (fixtures, reporter tests) and macOS
        // folded `Tests/` into it, so the tests physically live at `tests/LookoutTests`. Spelling
        // the real path here keeps the package building on a case-sensitive filesystem too.
        .testTarget(
            name: "LookoutTests",
            dependencies: ["Lookout"],
            path: "tests/LookoutTests"
        ),
    ]
)
