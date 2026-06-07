// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Wasm3Legacy",
    platforms: [.macOS(.v12), .iOS(.v12)],
    products: [
        .library(
            name: "Wasm3Legacy",
            targets: ["Wasm3Legacy"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Wasm3Legacy",
            dependencies: ["wasm3_legacy_c"]
        ),
        .target(
            name: "wasm3_legacy_c",
            cSettings: [
                .define("APPLICATION_EXTENSION_API_ONLY", to: "YES"),
                .define("d_m3MaxDuplicateFunctionImpl", to: "10"),
                .define("d_m3HasWASI", to: "YES"),
                .unsafeFlags(["-Wno-shorten-64-to-32"])
            ]
        ),
    ]
)
