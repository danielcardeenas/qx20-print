// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "QX20Print",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "QX20Print", targets: ["QX20Print"]),
        .executable(name: "qx20tool", targets: ["qx20tool"]),
    ],
    targets: [
        // Printer protocol, image preparation, JPEG encoder, Wi-Fi, Keychain
        .target(name: "QX20Core"),
        // SwiftUI desktop app
        .executableTarget(name: "QX20Print", dependencies: ["QX20Core"]),
        // Command line tool (render previews, print, status) for testing the core
        .executableTarget(name: "qx20tool", dependencies: ["QX20Core"]),
    ]
)
