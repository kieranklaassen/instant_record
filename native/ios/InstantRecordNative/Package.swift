// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "InstantRecordNative",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "InstantRecordNative", targets: ["InstantRecordNative"])],
    targets: [
        .target(name: "InstantRecordNative"),
        .testTarget(name: "InstantRecordNativeTests", dependencies: ["InstantRecordNative"]),
    ]
)
