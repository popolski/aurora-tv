// swift-tools-version: 6.0
//
// LanterneCore — logique métier indépendante de l'interface :
// protocole des addons Stremio, API de compte (non officielle), analyse et tri
// des sources, bibliothèque/progression, persistance et réglages.
//
// Aucune dépendance externe, aucun framework UIKit/AVFoundation : le paquet se
// compile et se teste sur macOS (`swift test`) comme sur tvOS.

import PackageDescription

let package = Package(
    name: "LanterneCore",
    defaultLocalization: "fr",
    platforms: [
        .tvOS(.v18),
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "LanterneCore", targets: ["LanterneCore"]),
    ],
    targets: [
        .target(
            name: "LanterneCore",
            path: "Sources/LanterneCore"
        ),
        .testTarget(
            name: "LanterneCoreTests",
            dependencies: ["LanterneCore"],
            path: "Tests/LanterneCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
