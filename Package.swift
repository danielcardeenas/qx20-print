// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "QX20Print",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "QX20Print", targets: ["QX20Print"]),
        .executable(name: "qx20", targets: ["qx20"]),
    ],
    targets: [
        // Printer protocol, image preparation, JPEG encoder, Wi-Fi, Keychain
        .target(name: "QX20Core"),
        // SwiftUI desktop app
        .executableTarget(name: "QX20Print", dependencies: ["QX20Core"]),
        // Command line tool for terminal users, scripts and AI agents
        .executableTarget(
            name: "qx20",
            dependencies: ["QX20Core"],
            linkerSettings: [
                // Embedded Info.plist: a command line tool needs a usage description
                // to ask for the Location permission (Wi-Fi network names).
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", Context.packageDirectory + "/Resources/qx20-Info.plist"]),
            ]
        ),
    ]
)
