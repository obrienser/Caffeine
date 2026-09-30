// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CaffeineCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CaffeineCore", targets: ["CaffeineCore"]),
        .library(name: "CaffeineServiceProtocol", targets: ["CaffeineServiceProtocol"]),
        .library(name: "CaffeineHelperCore", targets: ["CaffeineHelperCore"]),
        .library(name: "CaffeineSystemPower", targets: ["CaffeineSystemPower"]),
        .library(name: "CaffeineLogging", targets: ["CaffeineLogging"])
    ],
    targets: [
        .target(name: "CaffeineCore"),
        .target(name: "CaffeineLogging"),
        .target(name: "CaffeineServiceProtocol"),
        .target(name: "CaffeineHelperCore", dependencies: ["CaffeineServiceProtocol", "CaffeineLogging"]),
        .target(name: "CaffeineSystemPower", dependencies: ["CaffeineServiceProtocol", "CaffeineHelperCore", "CaffeineLogging"]),
        .testTarget(name: "CaffeineLoggingTests", dependencies: ["CaffeineLogging"]),
        .testTarget(name: "CaffeineCoreTests", dependencies: ["CaffeineCore"]),
        .testTarget(name: "CaffeineHelperCoreTests", dependencies: ["CaffeineHelperCore", "CaffeineServiceProtocol", "CaffeineLogging"]),
        .testTarget(name: "CaffeineSystemPowerTests", dependencies: ["CaffeineSystemPower", "CaffeineServiceProtocol", "CaffeineHelperCore", "CaffeineLogging"])
    ]
)
