// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LevoitBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LevoitBar",
            path: "Sources/LevoitBar"
        )
    ]
)
