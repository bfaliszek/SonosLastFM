// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SonosLastFM",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "SonosLastFM", targets: ["SonosLastFM"])],
    targets: [.executableTarget(name: "SonosLastFM")]
)
