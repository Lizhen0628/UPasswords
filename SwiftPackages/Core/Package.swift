// swift-tools-version:5.9
// UPasswordsCore — 跨平台领域核心：数据模型、XML 编解码、加密、密码生成/强度、
// TOTP、日志与本地化字符串表。不依赖任何 UI 框架。
import PackageDescription

let package = Package(
    name: "UPasswordsCore",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "UPasswordsCore", targets: ["UPasswordsCore"])
    ],
    targets: [
        .target(
            name: "UPasswordsCore",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["UPasswordsCore"],
            path: "Tests/CoreTests"
        )
    ]
)
