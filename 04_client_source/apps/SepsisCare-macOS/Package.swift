// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SepsisCare-macOS",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SepsisCare-macOS", targets: ["App"])
    ],
    targets: [
        .executableTarget(
            name: "App",
            path: "Sources/App",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "AppTests",
            dependencies: ["App"],
            path: "Tests/AppTests"
        )
    ]
)
