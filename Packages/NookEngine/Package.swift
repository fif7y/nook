// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NookEngine",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "NookEngine", targets: ["NookEngine"]),
        .executable(name: "nook-probe", targets: ["nook-probe"]),
    ],
    targets: [
        // ObjC shim: dlopen/NSClassFromString access to MenuBarClientCore's
        // assessment-mode classes. Kept ObjC so exceptions from private API
        // calls can be caught (@try/@catch) without tearing the process down.
        .target(
            name: "NookEngineObjC",
            path: "Sources/NookEngineObjC"
        ),
        .target(
            name: "NookEngine",
            dependencies: ["NookEngineObjC"],
            path: "Sources/NookEngine"
        ),
        // M1 spike harness. Throwaway: proves hide/reorder/enumerate/click on
        // this machine before any UI work starts.
        .executableTarget(
            name: "nook-probe",
            dependencies: ["NookEngine"],
            path: "Sources/nook-probe"
        ),
    ]
)
