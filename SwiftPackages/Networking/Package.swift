// swift-tools-version:5.9
// UPasswordsNetworking — 网络侧安全服务：HIBP k-匿名泄露检查与本地泄露清单。
import PackageDescription

let package = Package(
    name: "UPasswordsNetworking",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "UPasswordsNetworking", targets: ["UPasswordsNetworking"])
    ],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .target(
            name: "UPasswordsNetworking",
            dependencies: [
                .product(name: "UPasswordsCore", package: "Core")
            ]
        ),
        .testTarget(
            name: "NetworkingTests",
            dependencies: [
                "UPasswordsNetworking",
                .product(name: "UPasswordsCore", package: "Core")
            ],
            path: "Tests/NetworkingTests"
        )
    ]
)
