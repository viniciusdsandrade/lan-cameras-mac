// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CamerasDeCasa",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CamerasCore", targets: ["CamerasCore"]),
        .executable(name: "CamerasDeCasa", targets: ["CamerasApp"]),
        .executable(name: "camspike", targets: ["CamSpike"]),
    ],
    targets: [
        // Protocolos (RTSP, ONVIF, DVRIP), codecs e áudio. Sem dependências.
        .target(name: "CamerasCore"),
        // Janela SwiftUI.
        .executableTarget(name: "CamerasApp", dependencies: ["CamerasCore"]),
        // Ferramenta de linha de comando para testar vídeo e protocolos sem interface.
        .executableTarget(name: "CamSpike", dependencies: ["CamerasCore"]),
        .testTarget(name: "CamerasCoreTests", dependencies: ["CamerasCore"],
                    resources: [.copy("Fixtures")]),
    ]
)
