// swift-tools-version:6.0
import PackageDescription

// Kyutai STT is a Rust static archive (see Vendor/KyutaiKit and Scripts/build_stt.sh).
let kyutaiLib = Context.packageDirectory + "/Vendor/KyutaiKit/lib"

let package = Package(
    name: "Transcriptaze",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Transcriptaze", targets: ["Transcriptaze"]),
        .executable(name: "transcriptaze-mcp", targets: ["transcriptaze-mcp"]),
    ],
    targets: [
        .target(
            name: "CKyutai",
            linkerSettings: [
                .unsafeFlags(["-L", kyutaiLib]),
                .linkedLibrary("pendragon_stt"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalPerformanceShaders"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
            ]
        ),
        .target(name: "TranscriptazeCore", dependencies: ["CKyutai"]),
        .executableTarget(name: "Transcriptaze", dependencies: ["TranscriptazeCore"]),
        .executableTarget(name: "transcriptaze-mcp"),
        .testTarget(
            name: "TranscriptazeCoreTests",
            dependencies: ["TranscriptazeCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
