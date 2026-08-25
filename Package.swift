// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PrompterVideoMaker",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "PrompterVideoMaker",
            path: "Sources/PrompterVideoMaker",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PrompterVideoMakerTests",
            dependencies: ["PrompterVideoMaker"],
            path: "Tests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
