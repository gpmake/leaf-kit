// swift-tools-version:5.2
import PackageDescription

let package = Package(
    name: "leaf-kit",
    platforms: [
       .macOS(.v10_15)
    ],
    products: [
        .library(name: "LeafKit", targets: ["LeafKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.20.2"),
    ],
    targets: [
        .target(name: "LeafKit", dependencies: [
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOFoundationCompat", package: "swift-nio")
        ]),
        .testTarget(name: "LeafKitTests", dependencies: [
            .target(name: "LeafKit"),
        ]),
    ]
)
