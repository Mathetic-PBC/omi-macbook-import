// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OmiImportCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "OmiImportCore", targets: ["OmiImportCore"])],
    targets: [
        .target(name: "OmiImportCore"),
        .testTarget(name: "OmiImportCoreTests", dependencies: ["OmiImportCore"], resources: [.copy("Fixtures")]),
    ]
)
