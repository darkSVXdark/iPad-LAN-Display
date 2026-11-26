// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "iPadLANDisplay", platforms: [.macOS(.v14)], products: [.executable(name: "iPadLANDisplay", targets: ["iPadLANDisplay"])], targets: [.executableTarget(name: "iPadLANDisplay", path: "Sources")])
