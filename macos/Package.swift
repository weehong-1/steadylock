// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SteadyVolume",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "steadyvolumed", targets: ["steadyvolumed"]),
        .executable(name: "steadyvol", targets: ["steadyvol"]),
        .library(name: "SteadyVolumeCore", targets: ["SteadyVolumeCore"]),
    ],
    targets: [
        // Config, passwords, lockout, IPC, command processing and the enforcement engine.
        // No CoreAudio here, so everything in it can be unit-tested without touching real audio.
        .target(name: "SteadyVolumeCore"),
        .executableTarget(
            name: "steadyvolumed",
            dependencies: ["SteadyVolumeCore"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .executableTarget(name: "steadyvol", dependencies: ["SteadyVolumeCore"]),
        .testTarget(name: "SteadyVolumeCoreTests", dependencies: ["SteadyVolumeCore"]),
    ]
)
