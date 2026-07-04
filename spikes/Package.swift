// swift-tools-version: 5.10
// Throwaway spike package for SPEC.md §0 probes. Nothing here ships in the app.
import PackageDescription

let package = Package(
    name: "spikes",
    platforms: [.macOS(.v14)],
    dependencies: [
        // S1: verify the API surface at the pin the repo's Package.resolved records (0.15.4).
        // SPEC.md §2 said 0.12.4; the committed Package.resolved pins 0.15.4 — S1 resolves which.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.4"),
    ],
    targets: [
        .executableTarget(
            name: "api-spike",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/api-spike"),
        .executableTarget(
            name: "stream-spike",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/stream-spike"),
        .executableTarget(
            name: "recorder-probe",
            path: "Sources/recorder-probe"),
    ]
)
