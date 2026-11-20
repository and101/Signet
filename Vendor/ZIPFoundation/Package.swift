// swift-tools-version:5.9
// Vendored ZIPFoundation 0.9.20 with local patches; see PATCHES.md. Apple platforms only, so the
// zlib system-library variant and the upstream test target are left out.
import PackageDescription

let package = Package(
    name: "ZIPFoundation",
    platforms: [
        .macOS(.v10_13), .iOS(.v12), .tvOS(.v12), .watchOS(.v4), .visionOS(.v1)
    ],
    products: [
        .library(name: "ZIPFoundation", targets: ["ZIPFoundation"])
    ],
    targets: [
        .target(name: "ZIPFoundation", resources: [.copy("Resources/PrivacyInfo.xcprivacy")])
    ],
    swiftLanguageVersions: [.v4, .v4_2, .v5]
)
