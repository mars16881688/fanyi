// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Suiyi",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Suiyi",
            path: "Sources/Suiyi",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("Security"),
                .linkedFramework("NaturalLanguage"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI"),
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
