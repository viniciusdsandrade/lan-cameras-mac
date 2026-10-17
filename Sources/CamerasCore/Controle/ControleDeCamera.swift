import Foundation

public struct ControleErro: Error, CustomStringConvertible, Sendable {
    public let descricao: String
    public init(_ d: String) { descricao = Redact.texto(d) }
    public var description: String { descricao }
}

/// O que a câmera informa sobre si. Leitura apenas.
public struct EstadoDaCamera: Sendable, Equatable {
    public var luz: ModoDaLuz?
    public var rastreioLigado: Bool?
    public var rastreioVoltaEmSegundos: Int?
    public var sinalDoWiFi: Int?
    public var presets: [PresetDaCamera] = []
    /// Partes que não deu para ler (a câmera pode responder umas coisas e outras não).
    public var avisos: [String] = []
}

/// As operações de uma câmera que não são vídeo nem fala: estado, luz, rastreio e posições salvas.
/// Todas bloqueiam; o app as chama fora da thread principal.
public final class ControleDeCamera: Sendable {
    public let camera: CameraConfig
    private let armazenamento: ArmazenamentoDeCameras
    private let portaOnvif: UInt16
    private let portaDVRIP: UInt16

    public init(camera: CameraConfig, armazenamento: ArmazenamentoDeCameras = ArmazenamentoDeCameras(),
                portaOnvif: UInt16 = 8899, portaDVRIP: UInt16 = DVRIPClient.portaPadrao) {
        self.camera = camera
        self.armazenamento = armazenamento
        self.portaOnvif = portaOnvif
        self.portaDVRIP = portaDVRIP
    }

    private var onvif: ONVIFClient {
        ONVIFClient(host: camera.host, porta: portaOnvif, usuario: camera.usuario, hash: camera.hash)
    }

    private func comDVRIP<T>(_ corpo: (DVRIPClient) throws -> T) throws -> T {
        try DVRIPClient.executar(host: camera.host, porta: portaDVRIP, usuario: camera.usuario, hash: camera.hash, corpo)
    }

    /// Lê luz, rastreio, sinal e posições salvas sem mudar nada.
    public func lerEstado() -> EstadoDaCamera {
        var e = EstadoDaCamera()
        do {
            try comDVRIP { d in
                e.luz = try d.modoDaLuz()
                let r = try d.rastreio()
                e.rastreioLigado = r.ligado
                e.rastreioVoltaEmSegundos = r.voltaEmSegundos
                e.sinalDoWiFi = try? d.sinalDoWiFi()
            }
        } catch { e.avisos.append("a câmera não respondeu pelo DVRIP (\(error))") }
        do { e.presets = try onvif.presets() }
        catch { e.avisos.append("não consegui ler as posições salvas (\(error))") }
        return e
    }

    public func definirLuz(_ modo: ModoDaLuz) throws {
        try comDVRIP { try $0.definirLuz(modo) }
    }

    public func definirRastreio(_ ligado: Bool) throws {
        try comDVRIP { try $0.definirRastreio(ligado) }
    }

    public func pararMovimento() throws { try onvif.parar() }

    // MARK: - Posições salvas

    public func irParaPreset(_ token: String) throws {
        try onvif.irParaPreset(token)
    }

    /// Guarda a posição atual com um nome. Devolve o número que a câmera deu a ela.
    public func salvarPreset(nome: String) throws -> String {
        let limpo = String(nome.filter { !$0.isNewline && ($0.isLetter || $0.isNumber || $0.isPunctuation || $0.isSymbol || $0 == " ") }
            .trimmingCharacters(in: .whitespaces).prefix(24))
        guard !limpo.isEmpty else { throw ControleErro("dê um nome à posição") }
        let token = try onvif.salvarPreset(nome: limpo)
        try armazenamento.registrarPreset(token, camera: camera.id)
        return token
    }

    /// Só apaga o que este app criou: as posições que já vinham na câmera nunca são tocadas.
    public func apagarPreset(_ token: String) throws {
        guard armazenamento.presetsDoApp(camera: camera.id).contains(token) else {
            throw ControleErro("só apago posições criadas por este app")
        }
        try onvif.removerPreset(token)
        try armazenamento.esquecerPreset(token, camera: camera.id)
    }

    public func presetsCriadosPeloApp() -> Set<String> {
        armazenamento.presetsDoApp(camera: camera.id)
    }
}
