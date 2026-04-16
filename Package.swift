// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FolderMenu",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "FolderMenu",
            path: "Sources/FolderMenu",
            linkerSettings: [
                .linkedFramework("QuickLookUI"),
                .linkedFramework("CoreServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("PDFKit")
            ]
        )
    ]
)
