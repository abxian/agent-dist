// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacCameraAgent",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "MacCameraAgent", targets: ["MacCameraAgent"])
    ],
    targets: [
        .executableTarget(name: "MacCameraAgent")
    ]
)
