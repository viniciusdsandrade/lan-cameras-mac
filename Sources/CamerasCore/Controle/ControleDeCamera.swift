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
    /// Não é mais lido: a consulta do sinal (WifiRouteInfo) faz as XM535 varrerem o Wi-Fi enquanto transmitem
    /// vídeo, e com isso chegaram a travar e a perder o Wi-Fi (o registro de eventos delas mostra os dois em
    /// seguida). O campo fica, sempre vazio, porque o app de iPhone o lê.
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

    /// Lê luz, rastreio e posições salvas sem mudar nada. Não pergunta o sinal do Wi-Fi: veja `EstadoDaCamera`.
    public func lerEstado() -> EstadoDaCamera {
        var e = EstadoDaCamera()
        do {
            try comDVRIP { d in
                e.luz = try d.modoDaLuz()
                let r = try d.rastreio()
                e.rastreioLigado = r.ligado
                e.rastreioVoltaEmSegundos = r.voltaEmSegundos
            }
        } catch { e.avisos.append("não consegui ler luz e rastreio: \(error)") }
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

    // MARK: - Posição de descanso

    /// Faz de uma posição salva o lugar onde a câmera descansa: ela fica parada lá e, com o rastreio ligado, volta
    /// para lá `voltaEmSegundos` depois de perder o movimento. Vai até a posição, espera o motor parar, grava a
    /// vista como o ponto de vigia (a posição 100 do firmware) e liga o rastreio com esse tempo de volta. Fica
    /// gravado na câmera: vale com o Mac e o celular desligados.
    public func definirDescanso(em token: String, voltaEmSegundos: Int, esperarAte segundos: TimeInterval = 15) throws {
        guard let numero = Int(token), !DVRIPClient.posicoesDoFirmware.contains(numero) else {
            throw ControleErro("essa posição é da própria câmera; escolha uma das salvas")
        }
        try onvif.irParaPreset(token)
        try esperarParar(ate: segundos)
        try comDVRIP { d in
            try d.salvarPosicao(DVRIPClient.posicaoDeVigia)
            // confere na lista de posições, quando a câmera deixa ler
            if let salvas = try? d.posicoesSalvas(), !salvas.contains(DVRIPClient.posicaoDeVigia) {
                throw ControleErro("a câmera aceitou, mas não guardou o ponto de vigia")
            }
            try d.definirRastreio(true, voltaEmSegundos: voltaEmSegundos)
        }
        try armazenamento.registrarDescanso(token, camera: camera.id)
    }

    /// Muda só em quantos segundos sem movimento a câmera volta à posição de descanso (o rastreio fica ligado).
    public func definirVolta(emSegundos segundos: Int) throws {
        try comDVRIP { try $0.definirRastreio(true, voltaEmSegundos: segundos) }
    }

    /// A posição salva que este app gravou como o lugar de descanso da câmera, se gravou.
    public func descanso() -> String? { armazenamento.descanso(camera: camera.id) }

    /// Espera o motor parar: o firmware grava como ponto de vigia a vista em que a câmera estiver. As XiongMai
    /// respondem o estado do motor (ONVIF `GetStatus`), mas sempre "parado", mesmo andando: só depois de uma
    /// leitura "andando" vale esperar duas "parado" seguidas. Sem isso, espera o bastante para qualquer volta.
    private func esperarParar(ate segundos: TimeInterval) throws {
        let inicio = Date()
        let limite = inicio.addingTimeInterval(max(segundos, Self.esperaSemOMotor))
        Thread.sleep(forTimeInterval: Self.esperaParaComecar)        // o motor leva um instante para começar a andar
        var viuAndando = false
        var paradas = 0
        while Date() < limite {
            guard let andando = try? onvif.movendo() else { break }   // a câmera não informa o motor
            if andando {
                viuAndando = true
                paradas = 0
            } else if viuAndando {
                paradas += 1
                if paradas >= 2 { return }
            } else if Date().timeIntervalSince(inicio) >= Self.esperaSemOMotor {
                return                                                // nunca disse que andava: já deu tempo de sobra
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        if viuAndando { throw ControleErro("a câmera não terminou de ir até a posição") }
        let falta = Self.esperaSemOMotor - Date().timeIntervalSince(inicio)
        if falta > 0 { Thread.sleep(forTimeInterval: falta) }
    }

    /// Os testes encurtam as esperas. `esperaSemOMotor`: o bastante para a câmera dar a maior volta até uma posição
    /// (o vídeo mostra a câmera andando uns 2 s depois do pedido).
    nonisolated(unsafe) static var esperaParaComecar: TimeInterval = 1.5
    nonisolated(unsafe) static var esperaSemOMotor: TimeInterval = 10

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
