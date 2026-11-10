// swift-tools-version: 5.9
import PackageDescription

import Foundation

var testSwiftSettings: [SwiftSetting] = []
let cltTestingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
if FileManager.default.fileExists(atPath: cltTestingPlugins) {
    testSwiftSettings.append(.unsafeFlags([
        "-plugin-path", cltTestingPlugins
    ]))
}


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
