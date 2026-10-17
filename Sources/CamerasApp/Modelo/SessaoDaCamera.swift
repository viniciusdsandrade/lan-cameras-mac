import SwiftUI
import AppKit
import CamerasCore

enum Direcao: CaseIterable, Hashable {
    case cima, baixo, esquerda, direita

    /// `x > 0` vira à ESQUERDA: o firmware das câmeras tem o pan invertido.
    var vetor: (x: Double, y: Double) {
        switch self {
        case .cima: return (0, 1)
        case .baixo: return (0, -1)
        case .esquerda: return (1, 0)
        case .direita: return (-1, 0)
        }
    }

    var simbolo: String {
        switch self {
        case .cima: return "arrow.up"
        case .baixo: return "arrow.down"
        case .esquerda: return "arrow.left"
        case .direita: return "arrow.right"
        }
    }

    var nome: String {
        switch self {
        case .cima: return "cima"
        case .baixo: return "baixo"
        case .esquerda: return "esquerda"
        case .direita: return "direita"
        }
    }
}

/// Valor lido por threads de áudio e escrito pela interface.
final class Atomico<T>: @unchecked Sendable {
    private let trava = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var valor: T {
        get { trava.withLock { v } }
        set { trava.withLock { v = newValue } }
    }
}

/// Tudo o que se faz com uma câmera aberta na tela: vídeo, estado, movimento, posições salvas,
/// luz, rastreio, áudio, fala e foto. Existe enquanto a tela da câmera estiver aberta; `encerrar()`
/// solta a sessão de vídeo, o alto-falante e qualquer movimento em curso.
@MainActor
final class SessaoDaCamera: ObservableObject {
    let camera: CameraConfig
    let video: SessaoDeVideo
    let zoom = EstadoDeZoom()
    private weak var modelo: ModeloDoApp?
    private let controle: ControleDeCamera
    private let fala: GerenteDeFala
    private let escuta = Escuta()
    private var microfone: Microfone?
    private let ganho = Atomico<Double>(0.3)
    private lazy var movimento = MovimentoPTZ(camera: camera) { [weak self] mensagem in
        Task { @MainActor in self?.movimentoFalhou(mensagem) }
    }

    @Published private(set) var estado: EstadoDaCamera?
    @Published private(set) var ocupadas: Set<String> = []
    @Published private(set) var presetsDoApp: Set<String> = []
    @Published private(set) var direcoesAtivas: Set<Direcao> = []
    @Published private(set) var ouvindo = false
    @Published private(set) var falandoAoVivo = false
    @Published private(set) var nivelDoMicrofone: Float = 0
    @Published private(set) var ultimaFoto: URL?
    /// Valores que o usuário acabou de pedir, mostrados até a câmera confirmar.
    @Published private(set) var luzPedida: ModoDaLuz?
    @Published private(set) var rastreioPedido: Bool?

    private var tarefaDeEstado: Task<Void, Never>?
    private var medidor: Task<Void, Never>?
    private var ouvindoAntesDeFalar = false
    private var avisouDoRastreio = false
    private var encerrada = false

    init(camera: CameraConfig, modelo: ModeloDoApp) {
        self.camera = camera
        self.modelo = modelo
        video = SessaoDeVideo(camera: camera, stream: modelo.qualidadeHD ? .principal : .secundario, comAudio: true)
        controle = ControleDeCamera(camera: camera, armazenamento: modelo.armazenamento)
        fala = GerenteDeFala(camera: camera)
        ganho.valor = Self.ganho(de: modelo.volume)
        presetsDoApp = controle.presetsCriadosPeloApp()
        let escuta = self.escuta
        video.definirOuvinteDeAudio { escuta.empurrar($0) }
        video.iniciar()
        tarefaDeEstado = Task { [weak self] in await self?.cicloDeEstado() }
    }

    static func ganho(de volume: Double) -> Double { max(0.05, min(1.0, volume / 100)) }

    func volumeMudou(_ volume: Double) { ganho.valor = Self.ganho(de: volume) }

    // MARK: - Ciclo de vida

    func encerrar() {
        guard !encerrada else { return }
        encerrada = true
        tarefaDeEstado?.cancel()
        medidor?.cancel()
        pararMovimento()
        microfone?.parar()
        microfone = nil
        falandoAoVivo = false
        fala.parar()
        escuta.parar()
        ouvindo = false
        video.definirOuvinteDeAudio(nil)
        video.parar()
    }

    // MARK: - Estado (somente leitura)

    private func cicloDeEstado() async {
        await atualizarEstado()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            if Task.isCancelled { break }
            await atualizarEstado()
        }
    }

    func atualizarEstado() async {
        let c = controle
        let novo = await Task.detached(priority: .utility) { c.lerEstado() }.value
        guard !encerrada else { return }
        estado = novo
        presetsDoApp = controle.presetsCriadosPeloApp()
        if !ocupadas.contains("luz") { luzPedida = nil }
        if !ocupadas.contains("rastreio") { rastreioPedido = nil }
    }

    /// Roda uma operação que fala com a câmera, sem travar a tela; mostra o erro, se houver, e relê o estado.
    private func agir(_ chave: String, sucesso: String? = nil, _ corpo: @escaping @Sendable () throws -> Void) {
        guard !ocupadas.contains(chave) else { return }
        ocupadas.insert(chave)
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try corpo() }.value
                if let sucesso { modelo?.avisar(sucesso, .ok) }
            } catch {
                modelo?.avisar(Redact.texto(String(describing: error)), .erro)
                luzPedida = nil
                rastreioPedido = nil
            }
            ocupadas.remove(chave)
            await atualizarEstado()
        }
    }

    // MARK: - Movimento

    func segurar(_ d: Direcao) { atualizarDirecoes(direcoesAtivas.union([d])) }
    func soltar(_ d: Direcao) { atualizarDirecoes(direcoesAtivas.subtracting([d])) }

    func atualizarDirecoes(_ novas: Set<Direcao>) {
        direcoesAtivas = novas
        guard !novas.isEmpty else { movimento.parar(); return }
        let v = modelo?.velocidade ?? 0.4
        let x = max(-1, min(1, novas.reduce(0) { $0 + $1.vetor.x })) * v
        let y = max(-1, min(1, novas.reduce(0) { $0 + $1.vetor.y })) * v
        if estado?.rastreioLigado == true, !avisouDoRastreio {
            avisouDoRastreio = true
            let s = estado?.rastreioVoltaEmSegundos.map { "\($0) s" } ?? "alguns segundos"
            modelo?.avisar("Rastreio ligado: a câmera volta sozinha ao ponto de vigia depois de \(s).")
        }
        movimento.iniciar(x: x, y: y)
    }

    func pararMovimento() {
        direcoesAtivas = []
        movimento.parar()
    }

    private func movimentoFalhou(_ mensagem: String) {
        direcoesAtivas = []
        modelo?.avisar(Redact.texto(mensagem), .erro)
    }

    // MARK: - Posições salvas

    func irPara(_ p: PresetDaCamera) {
        let c = controle
        agir("preset-\(p.token)", sucesso: "Indo para \(p.nome)") { try c.irParaPreset(p.token) }
    }

    func salvarPosicao(nome: String) {
        let c = controle
        agir("salvar-preset", sucesso: "Posição salva") { _ = try c.salvarPreset(nome: nome) }
    }

    func apagar(_ p: PresetDaCamera) {
        let c = controle
        agir("apagar-\(p.token)", sucesso: "Posição apagada") { try c.apagarPreset(p.token) }
    }

    // MARK: - Luz e rastreio

    func definirLuz(_ modo: ModoDaLuz) {
        guard modo != (luzPedida ?? estado?.luz) else { return }
        luzPedida = modo
        let c = controle
        agir("luz", sucesso: "Luz: \(Self.nome(da: modo))") { try c.definirLuz(modo) }
    }

    func definirRastreio(_ ligado: Bool) {
        guard ligado != (rastreioPedido ?? estado?.rastreioLigado) else { return }
        rastreioPedido = ligado
        let c = controle
        agir("rastreio", sucesso: ligado ? "Rastreio ligado" : "Rastreio desligado") { try c.definirRastreio(ligado) }
    }

    static func nome(da modo: ModoDaLuz) -> String {
        switch modo {
        case .automatico: return "automática"
        case .ligada: return "ligada"
        case .desligada: return "desligada"
        }
    }

    // MARK: - Áudio

    func alternarOuvir() {
        if ouvindo {
            escuta.parar()
            ouvindo = false
        } else {
            do {
                try escuta.iniciar()
                ouvindo = true
            } catch {
                modelo?.avisar("Não consegui ligar o som: \(error.localizedDescription)", .erro)
            }
        }
    }

    func tocar(_ som: Som) {
        let g = fala, ganho = self.ganho
        agir("som", sucesso: "\(som.rotulo) tocando em \(camera.nome)") { try g.tocar(som.alaw, ganho: ganho.valor) }
    }

    func falarTexto(_ texto: String) {
        guard !texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let g = fala, ganho = self.ganho
        agir("texto", sucesso: "Falando em \(camera.nome)") {
            let alaw = try TextoFalado.alaw(texto: texto)
            try g.tocar(alaw, ganho: ganho.valor)
        }
    }

    func pararSom() {
        fala.parar()
        modelo?.avisar("Som parado")
    }

    /// Liga ou desliga a fala ao vivo (microfone do Mac para o alto-falante da câmera).
    func alternarFalaAoVivo() {
        if falandoAoVivo { pararFalaAoVivo(); return }
        guard !ocupadas.contains("fala-ao-vivo") else { return }
        ocupadas.insert("fala-ao-vivo")
        Task {
            defer { ocupadas.remove("fala-ao-vivo") }
            guard await Microfone.permitido() else {
                modelo?.avisar(Microfone.Falha.semPermissao.description, .erro)
                return
            }
            let g = fala, ganho = self.ganho
            do {
                try await Task.detached(priority: .userInitiated) { try g.iniciarAoVivo() }.value
                let mic = Microfone { bytes in g.enviarAoVivo(pcm16: bytes, ganho: ganho.valor) }
                try mic.iniciar()
                microfone = mic
                // meio-duplex: o que a câmera ouve e o que ela fala não podem se misturar
                ouvindoAntesDeFalar = ouvindo
                if ouvindo { escuta.parar(); ouvindo = false }
                falandoAoVivo = true
                iniciarMedidor()
            } catch {
                fala.pararAoVivo()
                modelo?.avisar(Redact.texto(String(describing: error)), .erro)
            }
        }
    }

    func pararFalaAoVivo() {
        guard falandoAoVivo else { return }
        microfone?.parar()
        microfone = nil
        fala.pararAoVivo()
        falandoAoVivo = false
        medidor?.cancel()
        nivelDoMicrofone = 0
        if ouvindoAntesDeFalar, !encerrada { alternarOuvir() }
        ouvindoAntesDeFalar = false
    }

    private func iniciarMedidor() {
        medidor?.cancel()
        medidor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, let mic = self.microfone else { break }
                self.nivelDoMicrofone = mic.nivel
            }
        }
    }

    // MARK: - Foto

    func tirarFoto() {
        guard let quadro = video.ultimoQuadro else {
            modelo?.avisar("Ainda não chegou imagem desta câmera.", .erro)
            return
        }
        let lente: Lente? = camera.duasLentes ? .movel : nil
        let nome = camera.nome
        Task {
            let url = await Task.detached(priority: .userInitiated) { () -> URL? in
                guard let dados = quadro.jpeg(lente: lente) else { return nil }
                let pasta = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Câmeras de Casa", isDirectory: true)
                try? FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
                let formato = DateFormatter()
                formato.locale = Locale(identifier: "en_US_POSIX")
                formato.dateFormat = "yyyyMMdd-HHmmss"
                let seguro = nome.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                let destino = pasta.appendingPathComponent("\(seguro)-\(formato.string(from: Date())).jpg")
                return (try? dados.write(to: destino)) != nil ? destino : nil
            }.value
            if let url {
                ultimaFoto = url
                modelo?.avisar("Foto salva em Imagens > Câmeras de Casa", .ok, arquivo: url)
            } else {
                modelo?.avisar("Não consegui salvar a foto.", .erro)
            }
        }
    }
}
