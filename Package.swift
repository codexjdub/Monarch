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
        ),
        .testTarget(
            name: "MonarchTests",
            dependencies: ["Monarch"],
            path: "Tests/MonarchTests",
            swiftSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-framework", "Testing",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                ])
            ]
        )
    ]
)
