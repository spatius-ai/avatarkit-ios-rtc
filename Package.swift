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
        .package(url: "https://github.com/spatius-ai/avatarkit-ios-release.git", exact: "1.3.6"),
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.30.0"),
        // Agora is pinned exactly, not to 4.5.x: with 4.5.3 the bridge compiles and the
        // encoded-frame interfaces it uses are unchanged in the headers, yet on a device the
        // observer receives no frames after a successful join (0 frames vs 106 with 4.5.2,
        // 2026-10-19). 4.6.x changed the callback signature. Re-test on a device before
        // moving this pin.
        .package(url: "https://github.com/AgoraIO/AgoraRtcEngine_iOS.git", exact: "4.5.2"),
    ],
    targets: [
        .target(
            name: "AvatarKitAgoraBridge",
            dependencies: [
                .product(name: "RtcBasic", package: "AgoraRtcEngine_iOS"),
            ],
            path: "AvatarKitRTC/Sources/AvatarKitAgoraBridge",
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
            path: "AvatarKitRTC/Sources/AvatarKitRTC"
        ),
        .testTarget(
            name: "AvatarKitRTCTests",
            dependencies: ["AvatarKitRTC"],
            path: "AvatarKitRTC/Tests/AvatarKitRTCTests"
        )
    ]
)
