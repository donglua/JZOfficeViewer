// swift-tools-version: 5.9
import PackageDescription

import Foundation

var testSwiftSettings: [SwiftSetting] = []
// In modern Swift 6+, Swift Testing plugin is automatically discovered via toolchain.
let package = Package(
    name: "JZOffice",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "JZOffice",
            targets: ["JZOffice"]
        ),
        .executable(
            name: "JZOfficeMacDemo",
            targets: ["JZOfficeMacDemo"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "CJZOffice",
            path: "libs/CJZOffice.xcframework"
        ),
        .target(
            name: "JZOffice",
            dependencies: ["CJZOffice"],
            path: "Sources/JZOffice",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("ImageIO")
            ]
        ),
        .executableTarget(
            name: "JZOfficeMacDemo",
            dependencies: ["JZOffice"],
            path: "Sources/JZOfficeMacDemo"
        ),
        .testTarget(
            name: "JZOfficeTests",
            dependencies: ["JZOffice"],
            path: "Tests/JZOfficeTests",
            swiftSettings: testSwiftSettings
        )
    ]
)
