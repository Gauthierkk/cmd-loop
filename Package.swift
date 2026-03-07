// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "cmdloop",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "cmdloop", path: "Sources/CmdLoop")
    ]
)
