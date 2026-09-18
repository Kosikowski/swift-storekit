// swift-tools-version: 6.2
// Spike, not product: what does a PACKAGE target see of DEBUG under each Xcode configuration?
import PackageDescription
let package = Package(name: "Flag", platforms: [.macOS(.v26)],
                      products: [.library(name: "Flag", targets: ["Flag"])],
                      targets: [.target(name: "Flag")])
