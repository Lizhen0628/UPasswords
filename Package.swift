// swift-tools-version:5.9
// UPasswords — Swift 1:1 replica of Safe.app ("Passwords & Codes - safe", SafeInCloud 25.3.5)
// Reverse-engineering basis: ../PasswordsCodes (interface-level ObjC restoration).

import PackageDescription

let package = Package(
    name: "UPasswords",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "UPasswords",
            path: "Sources/UPasswords",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "UPasswordsTests",
            dependencies: ["UPasswords"],
            path: "Tests/UPasswordsTests"
        )
    ]
)
