// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SkillHub",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SkillHub",
            path: "Sources/SkillHub",
            resources: [
                .process("Assets.xcassets")
            ]
        ),
        .testTarget(
            name: "SkillHubTests",
            dependencies: ["SkillHub"],
            path: "Tests/SkillHubTests"
        )
    ]
)
