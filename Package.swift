// swift-tools-version:6.0
import PackageDescription

// Kyutai STT is a Rust static archive (see Vendor/KyutaiKit and Scripts/build_stt.sh).
let kyutaiLib = Context.packageDirectory + "/Vendor/KyutaiKit/lib"

let package = Package(
    name: "Scriptorium",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Scriptorium", targets: ["Scriptorium"]),
        .executable(name: "scriptorium-mcp", targets: ["scriptorium-mcp"]),
    ],
    dependencies: [
        // Kokoro text-to-speech on the Neural Engine; fetches its CoreML model from Hugging Face on first use.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
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
        .target(name: "ScriptoriumCore", dependencies: ["CKyutai"]),
        .executableTarget(name: "Scriptorium", dependencies: ["ScriptoriumCore", .product(name: "FluidAudio", package: "FluidAudio")]),
        .executableTarget(name: "scriptorium-mcp"),
        .testTarget(
            name: "ScriptoriumCoreTests",
            dependencies: ["ScriptoriumCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
