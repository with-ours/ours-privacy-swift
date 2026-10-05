// swift-tools-version:6.0

import PackageDescription

// The Swift module is named `OursPrivacyKit` so consumers can `import
// OursPrivacyKit` and reference the `OursPrivacy` class without the module
// name shadowing the type.
let package = Package(
    name: "OursPrivacyKit",
    platforms: [
      .iOS(.v15),
      .tvOS(.v15),
      .macOS(.v12),
      .watchOS(.v8)
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
        .executableTarget(
            name: "RecorderProbe",
            dependencies: ["OursPrivacyKit"],
            path: "tools/recorder-probe"
        )
    ],
    swiftLanguageModes: [.v5]
)
