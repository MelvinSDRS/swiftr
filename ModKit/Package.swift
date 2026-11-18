// swift-tools-version: 6.2
import PackageDescription

// Mods: small JavaScript programs that describe panels, as herdr-app's do.
// The script runs in JavaScriptCore; Swiftr lays the panel out (Yoga) and
// draws it itself.
let package = Package(
    name: "ModKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ModKit", targets: ["ModKit"]),
    ],
    dependencies: [
        // Flexbox, which mods lay themselves out with.
        .package(url: "https://github.com/facebook/yoga", exact: "3.2.1"),
    ],
    targets: [
        // Yoga behind a plain C header: its own headers are C++.
        .target(name: "CFlex", dependencies: [.product(name: "yoga", package: "yoga")]),
        .target(
            name: "ModKit",
            dependencies: ["CFlex"],
            // The runtime mods run on, and the guide Swiftr writes for agents.
            resources: [.copy("Resources/prelude.js"), .copy("Resources/guide.md")],
            swiftSettings: [.defaultIsolation(MainActor.self)],
            // The system's zlib, for the `zlib` module.
            linkerSettings: [.linkedLibrary("z")]
        ),
        // `swiftr-mod check <folder>` and `swiftr-mod shot <folder> out.png`.
        .executableTarget(name: "swiftr-mod", dependencies: ["ModKit"], swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "ModKitTests", dependencies: ["ModKit"], swiftSettings: [.defaultIsolation(MainActor.self)]),
    ],
    cxxLanguageStandard: .cxx20
)
