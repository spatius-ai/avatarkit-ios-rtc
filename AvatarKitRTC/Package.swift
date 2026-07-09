// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AvatarKitRTC",
    platforms: [.iOS(.v16)],
    products: [
        .library(
            name: "AvatarKitRTC",
            targets: ["AvatarKitRTC"]
        ),
    ],
    dependencies: [
        // AvatarKit binary distribution. Pinned exactly to keep SPM and the
        // CocoaPods podspec on the same main-SDK version.
        .package(url: "https://github.com/spatius-ai/avatarkit-ios-release.git", exact: "1.3.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.30.0"),
        .package(url: "https://github.com/AgoraIO/AgoraRtcEngine_iOS.git", exact: "4.5.2"),
    ],
    targets: [
        .target(
            name: "AvatarKitAgoraBridge",
            dependencies: [
                .product(name: "RtcBasic", package: "AgoraRtcEngine_iOS"),
            ],
            path: "Sources/AvatarKitAgoraBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .define("OBJC_OLD_DISPATCH_PROTOTYPES", to: "1"),
            ]
        ),
        .target(
            name: "AvatarKitRTC",
            dependencies: [
                .product(name: "AvatarKit", package: "avatarkit-ios-release"),
                "AvatarKitAgoraBridge",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "RtcBasic", package: "AgoraRtcEngine_iOS"),
            ],
            path: "Sources/AvatarKitRTC"
        ),
        .testTarget(
            name: "AvatarKitRTCTests",
            dependencies: ["AvatarKitRTC"],
            path: "Tests/AvatarKitRTCTests"
        )
    ]
)
