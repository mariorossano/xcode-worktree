// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "xcode-worktree",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "XcodeWorktreeCore", targets: ["XcodeWorktreeCore"]),
        .executable(name: "XcodeWorktreeApp", targets: ["XcodeWorktreeApp"]),
    ],
    targets: [
        .target(name: "XcodeWorktreeCore"),
        .executableTarget(
            name: "XcodeWorktreeApp",
            dependencies: ["XcodeWorktreeCore"]
        ),
        .testTarget(
            name: "XcodeWorktreeCoreTests",
            dependencies: ["XcodeWorktreeCore"]
        ),
    ]
)
