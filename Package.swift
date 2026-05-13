// swift-tools-version:5.3

import PackageDescription

// The Swift module is named `OursPrivacyKit` so consumers can `import
// OursPrivacyKit` and reference the `OursPrivacy` class without the module
// name shadowing the type. See the React Native parity plan for context.
let package = Package(
    name: "OursPrivacyKit",
    platforms: [
      .iOS(.v13),
      .tvOS(.v13),
      .macOS(.v10_15),
      .watchOS(.v6)
    ],
    products: [
        .library(name: "OursPrivacyKit", targets: ["OursPrivacyKit"])
    ],
    targets: [
        .target(
            name: "OursPrivacyKit",
            path: "OursPrivacy",
            resources: [
                .copy("OursPrivacyResources/PrivacyInfo.xcprivacy"),
                .copy("OursPrivacyiOS.docc")
            ]
        ),
        .testTarget(
            name: "OursPrivacyKitTests",
            dependencies: ["OursPrivacyKit"],
            path: "Tests/OursPrivacyTests"
        ),
        .target(
            name: "RecorderProbe",
            dependencies: ["OursPrivacyKit"],
            path: "tools/recorder-probe"
        )
    ]
)
