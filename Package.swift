// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "LoopWorker",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "loopworker", targets: ["loopworker"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.0"),
        .package(url: "https://github.com/dduan/TOMLDecoder", from: "0.4.5"),
    ],
    targets: [
        .target(
            name: "LoopWorkerCore",
            dependencies: [.product(name: "TOMLDecoder", package: "TOMLDecoder")]
        ),
        .target(name: "GitLabBackend", dependencies: ["LoopWorkerCore"]),
        .executableTarget(
            name: "loopworker",
            dependencies: [
                "LoopWorkerCore",
                "GitLabBackend",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "LoopWorkerCoreTests", dependencies: ["LoopWorkerCore"]),
        .testTarget(name: "GitLabBackendTests", dependencies: ["GitLabBackend"]),
    ]
)
