// swift-tools-version:5.3

import PackageDescription

let package = Package(
    name: "OursPrivacy",
    platforms: [
      .iOS(.v11),
      .tvOS(.v11),
      .macOS(.v10_13),
      .watchOS(.v4)
    ],
    products: [
        .library(name: "OursPrivacy", targets: ["OursPrivacy"])
    ],
    targets: [
        .target(
            name: "OursPrivacy",
            path: "OursPrivacy",
            resources: [
                .copy("OursPrivacy/Resources/PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
