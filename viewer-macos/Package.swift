// swift-tools-version: 5.9
import PackageDescription

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
        .target(
            name: "CJZOffice",
            path: "Sources/CJZOffice",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags(["-L", "libs"]),
                .linkedLibrary("jz_office_macos")
            ]
        ),
        .target(
            name: "JZOffice",
            dependencies: ["CJZOffice"],
            path: "Sources/JZOffice"
        ),
        .executableTarget(
            name: "JZOfficeMacDemo",
            dependencies: ["JZOffice"],
            path: "Sources/JZOfficeMacDemo"
        ),
        .testTarget(
            name: "JZOfficeTests",
            dependencies: ["JZOffice"],
            path: "Tests/JZOfficeTests"
        )
    ]
)
