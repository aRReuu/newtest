// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ImpressReviewCore",
    platforms: [.iOS(.v14), .macOS(.v12)],
    products: [.library(name: "ImpressReviewCore", targets: ["ImpressReviewCore"])],
    targets: [
        .target(name: "ImpressReviewCore"),
        .testTarget(name: "ImpressReviewCoreTests", dependencies: ["ImpressReviewCore"])
    ]
)
