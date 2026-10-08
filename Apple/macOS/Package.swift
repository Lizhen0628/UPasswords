// swift-tools-version:5.9
// UPasswords — macOS 应用（SwiftUI + AppKit SPM 可执行目标）。
// 领域核心/持久化/网络服务来自 ../../SwiftPackages 下的本地包。
import PackageDescription

let package = Package(
    name: "UPasswords",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "../../SwiftPackages/Core"),
        .package(path: "../../SwiftPackages/Persistence"),
        .package(path: "../../SwiftPackages/Networking")
    ],
    targets: [
        .executableTarget(
            name: "UPasswords",
            dependencies: [
                .product(name: "UPasswordsCore", package: "Core"),
                .product(name: "UPasswordsPersistence", package: "Persistence"),
                .product(name: "UPasswordsNetworking", package: "Networking")
            ],
            path: "Sources/UPasswords",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "UPasswordsTests",
            dependencies: [
                "UPasswords",
                .product(name: "UPasswordsCore", package: "Core")
            ],
            path: "Tests/UPasswordsTests"
        )
    ]
)
