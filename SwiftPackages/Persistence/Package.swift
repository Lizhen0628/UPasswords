// swift-tools-version:5.9
// UPasswordsPersistence — 加密数据库文件存取、钥匙串、备份、iCloud 云同步与导入导出。
import PackageDescription

let package = Package(
    name: "UPasswordsPersistence",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "UPasswordsPersistence", targets: ["UPasswordsPersistence"])
    ],
    dependencies: [
        .package(path: "../Core")
    ],
    targets: [
        .target(
            name: "UPasswordsPersistence",
            dependencies: [
                .product(name: "UPasswordsCore", package: "Core")
            ]
        ),
        .testTarget(
            name: "PersistenceTests",
            dependencies: [
                "UPasswordsPersistence",
                .product(name: "UPasswordsCore", package: "Core")
            ],
            path: "Tests/PersistenceTests"
        )
    ]
)
