// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "InputLock",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "InputLock", targets: ["InputLock"])
    ],
    targets: [
        .executableTarget(
            name: "InputLock",
            path: "Sources/InputLock",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "InputLockTests",
            dependencies: ["InputLock"],
            path: "Tests/InputLockTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
