import Foundation
import Combine
import CamerasCore

/// Tudo o que se faz com uma câmera aberta na tela: vídeo, estado, movimento, posições salvas,
/// luz, rastreio, áudio, fala e foto. Existe enquanto a tela da câmera estiver aberta; `encerrar()`
/// solta a sessão de vídeo, o alto-falante e qualquer movimento em curso.
@MainActor
public final class SessaoDaCamera: ObservableObject {
    public let camera: CameraConfig
    public let video: SessaoDeVideo
    public let zoom = EstadoDeZoom()
    private weak var modelo: ModeloDoApp?
    private let controle: ControleDeCamera
    private let fala: GerenteDeFala
    private let escuta = Escuta()
    private var microfone: Microfone?
    private let ganho = Atomico<Double>(0.3)
    private lazy var movimento = MovimentoPTZ(camera: camera) { [weak self] mensagem in
        Task { @MainActor in self?.movimentoFalhou(mensagem) }
    }

    @Published public private(set) var estado: EstadoDaCamera?
    @Published public private(set) var ocupadas: Set<String> = []
    @Published public private(set) var presetsDoApp: Set<String> = []
    @Published public private(set) var direcoesAtivas: Set<Direcao> = []
    @Published public private(set) var ouvindo = false
    @Published public private(set) var falandoAoVivo = false
    @Published public private(set) var nivelDoMicrofone: Float = 0
    @Published public private(set) var ultimaFoto: URL?
    /// Valores que o usuário acabou de pedir, mostrados até a câmera confirmar.
    @Published public private(set) var luzPedida: ModoDaLuz?
    @Published public private(set) var rastreioPedido: Bool?

    private var tarefaDeEstado: Task<Void, Never>?
    private var medidor: Task<Void, Never>?
    private var ouvindoAntesDeFalar = false
    /// O usuário quer falar (botão apertado), mesmo que a fala ainda esteja começando.
    private var querFalar = false
    private var avisouDoRastreio = false
    private var encerrada = false

    public init(camera: CameraConfig, modelo: ModeloDoApp) {
        self.camera = camera
        self.modelo = modelo
        video = SessaoDeVideo(camera: camera, stream: modelo.qualidadeHD ? .principal : .secundario, comAudio: true)
        controle = ControleDeCamera(camera: camera, armazenamento: modelo.armazenamento)
        fala = GerenteDeFala(camera: camera)
        ganho.valor = Self.ganho(de: modelo.volume)
        presetsDoApp = controle.presetsCriadosPeloApp()
        let escuta = self.escuta
        video.definirOuvinteDeAudio { escuta.empurrar($0) }
        modelo.acompanhar(video)
        video.iniciar()
        tarefaDeEstado = Task { [weak self] in await self?.cicloDeEstado() }
    }

    public static func ganho(de volume: Double) -> Double { max(0.05, min(1.0, volume / 100)) }

    public func volumeMudou(_ volume: Double) { ganho.valor = Self.ganho(de: volume) }

    // MARK: - Ciclo de vida

    public func encerrar() {
        guard !encerrada else { return }
        encerrada = true
        tarefaDeEstado?.cancel()
        medidor?.cancel()
        pararMovimento()
        querFalar = false
        microfone?.parar()
        microfone = nil
        falandoAoVivo = false
        fala.parar()
        escuta.parar()
        ouvindo = false
        video.definirOuvinteDeAudio(nil)
        video.parar()
    }

    /// Ninguém mais está segurando nada (o app perdeu o foco, chegou uma ligação): para o
    /// movimento e a fala ao vivo, mas mantém o vídeo.
    public func soltarControles() {
        pararMovimento()
        pararFalaAoVivo()
    }

    /// O sistema tomou o áudio (ligação, alarme): para de ouvir e de falar.
    public func pararAudio() {
        pararFalaAoVivo()
        if ouvindo {
            escuta.parar()
            ouvindo = false
        }
    }

    // MARK: - Estado (somente leitura)

    /// Lê o estado de 10 em 10 s, menos enquanto a câmera estiver travada (aceita a conexão do vídeo e não
    /// responde): cada leitura abre duas conexões (DVRIP e ONVIF) que ela não atende e que só a atrasam. Se a
    /// leitura falhar por outro motivo, espera mais para tentar de novo.
    private func cicloDeEstado() async {
        while !Task.isCancelled {
            var espera = 1.0                                   // travada: olha de novo logo, ela pode voltar
            if !video.cameraMuda {
                await atualizarEstado()
                espera = estado?.avisos.isEmpty == false ? 30 : 10
            }
            try? await Task.sleep(for: .seconds(espera))
        }
    }

    public func atualizarEstado() async {
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

    public func segurar(_ d: Direcao) { atualizarDirecoes(direcoesAtivas.union([d])) }
    public func soltar(_ d: Direcao) { atualizarDirecoes(direcoesAtivas.subtracting([d])) }

    public func atualizarDirecoes(_ novas: Set<Direcao>) {
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

    public func pararMovimento() {
        direcoesAtivas = []
        movimento.parar()
    }

    private func movimentoFalhou(_ mensagem: String) {
        direcoesAtivas = []
        modelo?.avisar(Redact.texto(mensagem), .erro)
    }

    // MARK: - Posições salvas

    public func irPara(_ p: PresetDaCamera) {
        let c = controle
        agir("preset-\(p.token)", sucesso: "Indo para \(p.nome)") { try c.irParaPreset(p.token) }
    }

    public func salvarPosicao(nome: String) {
        let c = controle
        agir("salvar-preset", sucesso: "Posição salva") { _ = try c.salvarPreset(nome: nome) }
    }

    public func apagar(_ p: PresetDaCamera) {
        let c = controle
        agir("apagar-\(p.token)", sucesso: "Posição apagada") { try c.apagarPreset(p.token) }
    }

    // MARK: - Luz e rastreio

    public func definirLuz(_ modo: ModoDaLuz) {
        guard modo != (luzPedida ?? estado?.luz) else { return }
        luzPedida = modo
        let c = controle
        agir("luz", sucesso: "Luz: \(Self.nome(da: modo))") { try c.definirLuz(modo) }
    }

    public func definirRastreio(_ ligado: Bool) {
        guard ligado != (rastreioPedido ?? estado?.rastreioLigado) else { return }
        rastreioPedido = ligado
        let c = controle
        agir("rastreio", sucesso: ligado ? "Rastreio ligado" : "Rastreio desligado") { try c.definirRastreio(ligado) }
    }

    public static func nome(da modo: ModoDaLuz) -> String {
        switch modo {
        case .automatico: return "automática"
        case .ligada: return "ligada"
        case .desligada: return "desligada"
        }
    }

    // MARK: - Áudio

    public func alternarOuvir() {
        if ouvindo {
            escuta.parar()
            ouvindo = false
            Depuracao.registrar("\(camera.nome): ouvir desligado")
        } else {
            do {
                try escuta.iniciar()
                ouvindo = true
                Depuracao.registrar("\(camera.nome): ouvir ligado")
            } catch {
                modelo?.avisar("Não consegui ligar o som: \(error.localizedDescription)", .erro)
            }
        }
    }

    public func tocar(_ som: Som) {
        let g = fala, ganho = self.ganho
        Depuracao.registrar("\(camera.nome): tocar \(som.rotulo) com volume \(Int(ganho.valor * 100))%")
        agir("som", sucesso: "\(som.rotulo) tocando em \(camera.nome)") { try g.tocar(som.alaw, ganho: ganho.valor) }
    }

    public func falarTexto(_ texto: String) {
        guard !texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let g = fala, ganho = self.ganho
        agir("texto", sucesso: "Falando em \(camera.nome)") {
            let alaw = try TextoFalado.alaw(texto: texto)
            try g.tocar(alaw, ganho: ganho.valor)
        }
    }

    public func pararSom() {
        fala.parar()
        modelo?.avisar("Som parado")
    }

    /// Liga ou desliga a fala ao vivo (microfone do aparelho para o alto-falante da câmera).
    public func alternarFalaAoVivo() {
        if falandoAoVivo || querFalar { pararFalaAoVivo() } else { iniciarFalaAoVivo() }
    }

    /// Começa a fala ao vivo. Pode ser chamada ao apertar um botão de "segurar para falar":
    /// se o botão for solto antes de a câmera aceitar, a fala é desfeita assim que começa.
    public func iniciarFalaAoVivo() {
        guard !querFalar, !falandoAoVivo, !encerrada else { return }
        querFalar = true
        guard !ocupadas.contains("fala-ao-vivo") else { return }
        ocupadas.insert("fala-ao-vivo")
        Task {
            defer { ocupadas.remove("fala-ao-vivo") }
            guard await Microfone.permitido() else {
                querFalar = false
                modelo?.avisar(Microfone.Falha.semPermissao.description, .erro)
                return
            }
            guard querFalar, !encerrada else { return }               // soltou antes de começar
            let g = fala, ganho = self.ganho
            do {
                try await Task.detached(priority: .userInitiated) { try g.iniciarAoVivo() }.value
                guard querFalar, !encerrada else { fala.pararAoVivo(); return }
                let mic = Microfone { bytes in g.enviarAoVivo(pcm16: bytes, ganho: ganho.valor) }
                try mic.iniciar()
                microfone = mic
                // meio-duplex: o que a câmera ouve e o que ela fala não podem se misturar
                ouvindoAntesDeFalar = ouvindo
                if ouvindo { escuta.parar(); ouvindo = false }
                falandoAoVivo = true
                Depuracao.registrar("\(camera.nome): fala ao vivo começou\(ouvindoAntesDeFalar ? " (ouvir silenciado)" : "")")
                iniciarMedidor()
            } catch {
                querFalar = false
                fala.pararAoVivo()
                modelo?.avisar(Redact.texto(String(describing: error)), .erro)
            }
        }
    }

    public func pararFalaAoVivo() {
        querFalar = false
        guard falandoAoVivo else { return }
        microfone?.parar()
        microfone = nil
        fala.pararAoVivo()
        falandoAoVivo = false
        Depuracao.registrar("\(camera.nome): fala ao vivo terminou")
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

    public func tirarFoto() {
        guard let quadro = video.ultimoQuadro else {
            modelo?.avisar("Ainda não chegou imagem desta câmera.", .erro)
            return
        }
        let lente: Lente? = camera.duasLentes ? .movel : nil
        let nome = camera.nome
        Task {
            let dados = await Task.detached(priority: .userInitiated) { quadro.jpeg(lente: lente) }.value
            guard let dados else {
                modelo?.avisar("Não consegui gerar a foto.", .erro)
                return
            }
            do {
                let guardada = try await Plataforma.guardarFoto(dados, nomeDaCamera: nome)
                ultimaFoto = guardada.arquivo
                modelo?.avisar("Foto salva em \(guardada.onde)", .ok, arquivo: guardada.arquivo)
            } catch {
                modelo?.avisar("Não consegui salvar a foto: \(Redact.texto(String(describing: error)))", .erro)
            }
        }
    }
}
