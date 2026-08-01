// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FlightStudio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FlightStudio",
            path: "Sources/FlightStudio"
        )
    ]
)
