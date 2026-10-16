// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuotaDock",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "QuotaDock", targets: ["QuotaDock"]), .library(name: "QuotaDockCore", targets: ["QuotaDockCore"])],
    targets: [
        .target(name: "QuotaDockCore"),
        .executableTarget(name: "QuotaDockUpdater", dependencies: ["QuotaDockCore"]),
        .executableTarget(name: "QuotaDock", dependencies: ["QuotaDockCore"], resources: [.copy("Resources/ToolLogos"), .copy("Resources/Branding")]),
        .testTarget(name: "QuotaDockCoreTests", dependencies: ["QuotaDockCore"])
    ]
)
