// swift-tools-version: 6.2
//
// Spike, not product. Answers two questions the main package's test strategy
// hangs on, and is kept so the answers can be re-run on a new Xcode:
//
//   1. Does StoreKitTest's SKTestSession work in a PACKAGE test target under
//      plain `swift test`, with the .storekit file as a copied resource?
//   2. Does `Transaction.currentEntitlements` end early when the task that is
//      iterating it has been cancelled?
//
import PackageDescription

let package = Package(
    name: "sktestsession-spike",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "Spike"),
        .testTarget(
            name: "SpikeTests", dependencies: ["Spike"],
            resources: [.copy("Spike.storekit")],
            swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
