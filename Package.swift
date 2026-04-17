// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Monarch",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Monarch",
            path: "Sources/Monarch",
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
