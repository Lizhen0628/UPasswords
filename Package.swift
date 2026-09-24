// swift-tools-version:5.9
// UPasswords — an independently developed password manager for macOS
// (SwiftUI + AppKit, SPM executable target).

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
