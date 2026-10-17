import Foundation
import CamerasCore

/// O vídeo de uma câmera na tela: um fluxo RTSP (que ocupa uma sessão na câmera) mais o
/// reparte de quadros entre as telas que o mostram.
@MainActor
final class SessaoDeVideo: ObservableObject {
    let camera: CameraConfig
    let stream: StreamDeVideo
    let distribuidor = DistribuidorDeQuadros()
    @Published private(set) var estado: FluxoDeVideo.Estado = .parado
    private let fluxo: FluxoDeVideo

    init(camera: CameraConfig, stream: StreamDeVideo, comAudio: Bool = false) {
        self.camera = camera
        self.stream = stream
        fluxo = FluxoDeVideo(url: camera.urlDeVideo(stream), incluirAudio: comAudio)
        let distribuidor = self.distribuidor
        fluxo.aoReceberQuadro = { distribuidor.distribuir($0) }
        let rotulo = "\(camera.nome) (\(stream))"
        fluxo.aoMudarEstado = { [weak self] novo in
            Depuracao.registrar("\(rotulo): \(novo)")
            Task { @MainActor in self?.estado = novo }
        }
    }

    func iniciar() { fluxo.iniciar() }

    /// Libera a sessão na câmera (elas aguentam poucas).
    func parar() { fluxo.parar() }

    var ultimoQuadro: QuadroDecodificado? { fluxo.ultimoQuadro }

    /// Quem recebe o áudio da câmera (nil para ignorar).
    func definirOuvinteDeAudio(_ f: (@Sendable (RTPPacket) -> Void)?) { fluxo.aoReceberAudio = f }

    deinit { fluxo.parar() }
}
