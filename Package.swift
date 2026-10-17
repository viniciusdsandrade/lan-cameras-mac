// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CamerasDeCasa",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CamerasCore", targets: ["CamerasCore"]),
        .library(name: "CamerasSessao", targets: ["CamerasSessao"]),
        .executable(name: "CamerasDeCasa", targets: ["CamerasApp"]),
        .executable(name: "camspike", targets: ["CamSpike"]),
    ],
    targets: [
        // Protocolos (RTSP, ONVIF, DVRIP), codecs e áudio. Sem dependências.
        .target(name: "CamerasCore"),
        // O que as telas do Mac e do iPhone usam igual: sessões nas câmeras, câmera aberta, zoom, avisos.
        .target(name: "CamerasSessao", dependencies: ["CamerasCore"]),
        // Janela SwiftUI do Mac.
        .executableTarget(name: "CamerasApp", dependencies: ["CamerasCore", "CamerasSessao"]),
        // Ferramenta de linha de comando para testar vídeo e protocolos sem interface.
        .executableTarget(name: "CamSpike", dependencies: ["CamerasCore"]),
        .testTarget(name: "CamerasCoreTests", dependencies: ["CamerasCore"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "CamerasSessaoTests", dependencies: ["CamerasSessao", "CamerasCore"]),
    ]
)
