import Foundation
import Combine
import CamerasCore

/// O vídeo de uma câmera na tela: um fluxo RTSP (que ocupa uma sessão na câmera) mais o
/// reparte de quadros entre as telas que o mostram.
@MainActor
public final class SessaoDeVideo: ObservableObject {
    public let camera: CameraConfig
    public let stream: StreamDeVideo
    public let distribuidor = DistribuidorDeQuadros()
    @Published public private(set) var estado: FluxoDeVideo.Estado = .parado
    /// A câmera recusou o usuário e a senha guardados e o fluxo parou de tentar: quem abriu a
    /// sessão decide o que fazer (o modelo pega a senha atual com a própria câmera).
    public var aoRecusarCredenciais: (@MainActor () -> Void)?
    /// A câmera não responde no endereço guardado (várias conexões seguidas sem imagem) e o fluxo segue
    /// tentando: quem abriu a sessão pode procurá-la na rede. `primeiraVez` é falso nos avisos que se
    /// repetem enquanto ela não voltar.
    public var aoNaoResponder: (@MainActor (_ primeiraVez: Bool) -> Void)?
    private let fluxo: FluxoDeVideo

    public init(camera: CameraConfig, stream: StreamDeVideo, comAudio: Bool = false) {
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
        fluxo.aoRecusarCredenciais = { [weak self] in
            Task { @MainActor in self?.aoRecusarCredenciais?() }
        }
        fluxo.aoNaoResponder = { [weak self] primeiraVez in
            Task { @MainActor in self?.aoNaoResponder?(primeiraVez) }
        }
    }

    public func iniciar() { fluxo.iniciar() }

    /// Libera a sessão na câmera (elas aguentam poucas).
    public func parar() { fluxo.parar() }

    public var ultimoQuadro: QuadroDecodificado? { fluxo.ultimoQuadro }

    /// Quem recebe o áudio da câmera (nil para ignorar).
    public func definirOuvinteDeAudio(_ f: (@Sendable (RTPPacket) -> Void)?) { fluxo.aoReceberAudio = f }

    deinit { fluxo.parar() }
}
