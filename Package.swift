// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "murmur-smoke", targets: ["murmur-smoke"]),
    ],
    dependencies: [
        // EXACT pin (SPEC §2): pre-1.0 packages break API across 0.x. 0.15.4 is the version the
        // §0 spikes verified (S1–S5). Bump deliberately and re-run the spikes.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.4"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
    ],
    targets: [
        // ALL logic lives here (SPEC §11). Everything testable without a GUI or permissions.
        .target(
            name: "MurmurKit",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/MurmurKit"
        ),
        // Headless fixture transcribe — the earliest milestone (SPEC §10.2). No GUI, no
        // permissions, no session dir: WAV in, text out.
        .executableTarget(
            name: "murmur-smoke",
            dependencies: ["MurmurKit"],
            path: "Sources/murmur-smoke"
        ),
        .testTarget(
            name: "MurmurTests",
            dependencies: ["MurmurKit"],
            path: "Tests/MurmurTests"
            // Fixtures resolve at runtime via #filePath (Tests/Fixtures) — SwiftPM disallows
            // resource paths outside the target directory.
        ),
    ]
)
