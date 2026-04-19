// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Monarch",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Monarch",
            path: "Sources/Monarch",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("QuickLookUI"),
                .linkedFramework("CoreServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("PDFKit"),
                .linkedFramework("QuickLookThumbnailing")
            ]
        )
    ]
)
