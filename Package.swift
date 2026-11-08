// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ZephyrVM",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Zephyr", targets: ["ZephyrApp"]),
        .executable(name: "zephyrctl", targets: ["zephyrctl"]),
        .library(name: "ZephyrCore", targets: ["ZephyrCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.3.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.31.0"),
        // Newer swift-collections need stdlib APIs missing from the MacOSX26.5 SDK that build.sh uses.
        .package(url: "https://github.com/apple/swift-collections.git", "1.2.0"..<"1.4.0"),
    ],
    targets: [
        .target(
            name: "ZephyrCore",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedLibrary("compression"),
            ]
        ),
        .executableTarget(name: "zephyrctl", dependencies: ["ZephyrCore"]),
        .executableTarget(name: "ZephyrApp", dependencies: ["ZephyrCore"]),
    ],
    swiftLanguageModes: [.v5]
)
