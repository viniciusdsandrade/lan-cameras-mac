import SwiftUI
import CamerasCore

/// O estado do app inteiro: câmeras guardadas, o que está na tela, as sessões abertas nas câmeras,
/// a gravação por movimento, avisos e preferências. É o mesmo no Mac e no iPhone; o que muda (janela, segundo plano) fica
/// em `CicloDeVida.swift`.
@MainActor
public final class ModeloDoApp: ObservableObject {
    public enum Selecao: Hashable, Sendable {
        case geral
        case camera(String)
    }

    @Published public private(set) var cameras: [CameraConfig] = []
    @Published public private(set) var selecao: Selecao = .geral
    /// Visão geral: um fluxo leve (secundário) por câmera.
    @Published public private(set) var sessoesGerais: [String: SessaoDeVideo] = [:]
    /// Tela de uma câmera: vídeo, estado e controles.
    @Published public private(set) var sessaoDaCamera: SessaoDaCamera?
    @Published public var aviso: Aviso?
    @Published public private(set) var procurando = false

    // Preferências do usuário
    @AppStorage("qualidadeHD") public var qualidadeHD = true
    @AppStorage("mostrarLenteFixa") public var mostrarLenteFixa = Plataforma.mostrarLenteFixaPorPadrao
    @AppStorage("velocidade") public var velocidade = 0.4
    @AppStorage("volume") public var volume = 30.0

    public let armazenamento: ArmazenamentoDeCameras
    /// Gravação por movimento: segue com a janela escondida, ao contrário das sessões da tela.
    public let gravacao: GravacaoPorMovimento
    /// Sessões soltas porque ninguém está vendo (janela escondida, app em segundo plano, aparelho dormindo).
    private(set) var pausado = false
    var observadores: [NSObjectProtocol] = []
    private var pausaAgendada: Task<Void, Never>?
    private let argumentos: [String]
    private let reidentificar: @Sendable (CameraConfig) throws -> CameraConfig
    /// Câmeras cujas credenciais estão sendo pegas de novo (uma vez por câmera de cada vez).
    private var renovando: Set<String> = []

    /// `argumentos`: `--abrir NOME`, `--qualidade leve|hd`, `--zoom N` abrem direto num estado (útil em testes).
    /// `reidentificar`: como pegar de novo os dados de uma câmera que recusou a senha ou parou de
    /// responder (os testes trocam). `pastaDeGravacoes` e `agora`: onde a gravação por movimento
    /// guarda os arquivos e que horas são para ela (os testes trocam).
    public init(armazenamento: ArmazenamentoDeCameras = ArmazenamentoDeCameras(),
                argumentos: [String] = ProcessInfo.processInfo.arguments,
                observarCicloDeVida: Bool = true,
                reidentificar: @escaping @Sendable (CameraConfig) throws -> CameraConfig = { try Cadastro.reidentificar($0) },
                pastaDeGravacoes: URL = Plataforma.pastaDeGravacoes,
                agora: @escaping () -> Date = Date.init) {
        self.armazenamento = armazenamento
        self.argumentos = argumentos
        self.reidentificar = reidentificar
        gravacao = GravacaoPorMovimento(armazenamento: armazenamento, pasta: pastaDeGravacoes, agora: agora)
        gravacao.modelo = self
        recarregarCameras()
        aplicarArgumentos()
        ajustarSessoes()
        if observarCicloDeVida { self.observarCicloDeVida() }
    }

    // MARK: - Câmeras

    public func recarregarCameras() {
        cameras = (try? armazenamento.carregar()) ?? []
        gravacao.atualizar(cameras: cameras)
    }

    public func camera(id: String) -> CameraConfig? { cameras.first { $0.id == id } }

    public func renomear(_ camera: CameraConfig, para nome: String) {
        let limpo = nome.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpo.isEmpty else { return }
        try? armazenamento.atualizar(camera.id) { $0.nome = limpo }
        recarregarCameras()
    }

    /// Põe as câmeras na ordem dada (a da visão geral e dos atalhos).
    public func reordenar(_ ids: [String]) {
        for (i, id) in ids.enumerated() { try? armazenamento.atualizar(id) { $0.ordem = i } }
        recarregarCameras()
    }

    // MARK: - Seleção e sessões

    public func selecionar(_ nova: Selecao) {
        guard nova != selecao else { return }
        selecao = nova
        ajustarSessoes()
    }

    /// No máximo 3 sessões RTSP abertas (a visão geral usa uma por câmera; a tela de uma câmera,
    /// uma só): ao trocar de tela, o que não vale mais é fechado antes.
    private func ajustarSessoes() {
        guard !pausado else { return }
        switch selecao {
        case .geral:
            sessaoDaCamera?.encerrar()
            sessaoDaCamera = nil
            for c in cameras where sessoesGerais[c.id] == nil {
                let s = SessaoDeVideo(camera: c, stream: .secundario)
                acompanhar(s)
                s.iniciar()
                sessoesGerais[c.id] = s
            }
        case .camera(let id):
            for s in sessoesGerais.values { s.parar() }
            sessoesGerais = [:]
            guard let c = camera(id: id) else { selecao = .geral; ajustarSessoes(); return }
            if sessaoDaCamera?.camera.id != c.id {
                sessaoDaCamera?.encerrar()
                let nova = SessaoDaCamera(camera: c, modelo: self)
                if let z = argumentoNumerico("--zoom") { nova.zoom.definir(z) }
                sessaoDaCamera = nova
            }
        }
    }

    /// Libera todas as sessões (ninguém está vendo) sem perder a seleção.
    public func pausar() {
        pausaAgendada?.cancel()
        guard !pausado else { return }
        Depuracao.registrar("pausar: soltando as sessões")
        pausado = true
        for s in sessoesGerais.values { s.parar() }
        sessoesGerais = [:]
        sessaoDaCamera?.encerrar()
        sessaoDaCamera = nil
    }

    public func retomar() {
        guard pausado else { return }
        Depuracao.registrar("retomar: reabrindo as sessões")
        pausado = false
        ajustarSessoes()
    }

    public func pausarDepois(segundos: Double) {
        pausaAgendada?.cancel()
        pausaAgendada = Task {
            try? await Task.sleep(for: .seconds(segundos))
            if !Task.isCancelled { pausar() }
        }
    }

    public func retomarDepois(segundos: Double) {
        pausaAgendada?.cancel()
        pausaAgendada = Task {
            if segundos > 0 { try? await Task.sleep(for: .seconds(segundos)) }
            if !Task.isCancelled { retomar() }
        }
    }

    public func recomecarSessaoDaCamera() {
        guard case .camera = selecao else { return }
        sessaoDaCamera?.encerrar()
        sessaoDaCamera = nil
        ajustarSessoes()
    }

    // MARK: - Cadastro

    /// Acha as câmeras da rede e guarda as novas (as que já existem mantêm nome e ordem).
    public func procurarCameras() {
        guard !procurando else { return }
        procurando = true
        avisar("Procurando câmeras na rede…")
        let aparelho = Plataforma.esteAparelho
        Task {
            var r = await Self.procurarFora()
            #if os(iOS)
            // Na primeira vez o iOS pergunta se o app pode usar a rede local, e a busca que disparou
            // a pergunta não chega a lugar nenhum: tenta de novo depois de o usuário responder.
            if case .success(let achado) = r, achado.cameras.isEmpty {
                try? await Task.sleep(for: .seconds(3))
                r = await Self.procurarFora()
            }
            #endif
            procurando = false
            switch r {
            case .failure(let erro):
                avisar("Não consegui procurar: \(Redact.texto(String(describing: erro)))", .erro)
            case .success(let achado):
                guardar(achado.cameras, falhas: achado.falhas, aparelho: aparelho)
            }
        }
    }

    private nonisolated static func procurarFora() async -> Result<Cadastro.Resultado, Error> {
        await Task.detached(priority: .userInitiated) { Result { try Cadastro.procurarNaRede(duracao: 4) } }.value
    }

    public func adicionarPorEndereco(_ texto: String) {
        guard let host = Cadastro.enderecoValido(texto) else {
            avisar("Esse endereço não parece válido. Use o endereço IP da câmera: quatro números separados por pontos.", .erro)
            return
        }
        guard !procurando else { return }
        procurando = true
        let aparelho = Plataforma.esteAparelho
        Task {
            let r = await Task.detached(priority: .userInitiated) { () -> Result<CameraConfig, Error> in
                Result { try Cadastro.identificar(host: host, nome: "Câmera") }
            }.value
            procurando = false
            switch r {
            case .failure(let erro): avisar("Não achei uma câmera nesse endereço: \(Redact.texto(String(describing: erro)))", .erro)
            case .success(let c): guardar([c], falhas: [], aparelho: aparelho)
            }
        }
    }

    private func guardar(_ novas: [CameraConfig], falhas: [String], aparelho: String) {
        guard !novas.isEmpty else {
            avisar(falhas.isEmpty ? "Nenhuma câmera respondeu. Confira se \(aparelho) está no mesmo Wi-Fi que elas." : "Achei aparelhos, mas não consegui identificá-los.", .erro)
            return
        }
        do { try armazenamento.mesclar(novas) }
        catch { avisar("Não consegui guardar as câmeras: \(error.localizedDescription)", .erro); return }
        recarregarCameras()
        reiniciarSessoes()
        avisar(novas.count == 1 ? "Câmera guardada." : "Guardei \(novas.count) câmeras.", .ok)
    }

    /// Fecha e reabre os fluxos (depois de o endereço de uma câmera mudar, por exemplo).
    public func reiniciarSessoes() {
        for s in sessoesGerais.values { s.parar() }
        sessoesGerais = [:]
        sessaoDaCamera?.encerrar()
        sessaoDaCamera = nil
        ajustarSessoes()
    }

    public func pararTodas() {
        let todas = cameras
        Task {
            let erros = await Task.detached(priority: .userInitiated) { MovimentoPTZ.pararTodas(todas) }.value
            if erros.isEmpty { avisar("Todas as câmeras paradas", .ok) }
            else { avisar(erros.map(Redact.texto).joined(separator: "; "), .erro) }
        }
    }

    // MARK: - Senha ou endereço trocados

    /// Por que os dados guardados de uma câmera deixaram de servir.
    enum MotivoDaRenovacao: Equatable {
        /// Ela recusou o usuário e a senha: o app do fabricante (iCSee, XMEye) pode ter trocado a senha.
        case senhaRecusada
        /// Ela não responde no endereço guardado: o roteador pode ter dado outro a ela, e o dela a
        /// outro aparelho. O aviso se repete enquanto ela não voltar; só o primeiro vai para a tela.
        case semResposta(primeiraVez: Bool)
    }

    /// Acompanha o vídeo de uma câmera: se ela recusar a senha ou parar de responder, renova os dados dela.
    func acompanhar(_ sessao: SessaoDeVideo) {
        let c = sessao.camera
        sessao.aoRecusarCredenciais = { [weak self] in self?.renovarDados(de: c, porque: .senhaRecusada) }
        sessao.aoNaoResponder = { [weak self] primeiraVez in
            self?.renovarDados(de: c, porque: .semResposta(primeiraVez: primeiraVez))
        }
    }

    /// O app do fabricante pode trocar a senha de uma câmera, e o roteador, o endereço: pega os atuais
    /// com a própria câmera (ou procurando na rede pelo número de série), guarda e reabre só as sessões
    /// dela. Se ela devolver o mesmo que já estava guardado, não reabre nada: insistir com uma senha
    /// recusada pode fazer a câmera bloquear a conta.
    func renovarDados(de camera: CameraConfig, porque motivo: MotivoDaRenovacao) {
        guard !renovando.contains(camera.id) else { return }
        renovando.insert(camera.id)
        let senha = motivo == .senhaRecusada
        // Quem segue sem responder já foi avisado: daí em diante só o que mudar aparece na tela.
        let naTela = motivo != .semResposta(primeiraVez: false)
        func informar(_ texto: String, _ tipo: Aviso.Tipo = .info) {
            if naTela { avisar(texto, tipo) } else { Depuracao.registrar(texto) }
        }
        informar(senha ? "\(camera.nome) não aceitou a senha guardada: pegando a atual com a própria câmera…"
                     : "\(camera.nome) não responde no endereço guardado: procurando na rede…")
        let reidentificar = self.reidentificar
        Task {
            let r = await Task.detached(priority: .userInitiated) { Result { try reidentificar(camera) } }.value
            renovando.remove(camera.id)
            switch r {
            case .failure(let erro):
                let porque = Redact.texto(String(describing: erro))
                informar(senha ? "\(camera.nome) não aceitou a senha guardada e não consegui pegar a atual: \(porque)"
                             : "\(camera.nome) não responde e não consegui achá-la: \(porque)", .erro)
            case .success(let nova) where nova.host == camera.host && nova.usuario == camera.usuario && nova.hash == camera.hash:
                informar(senha ? "\(camera.nome) recusou a senha que ela mesma informa. Tente de novo daqui a alguns minutos."
                             : "\(camera.nome) responde no endereço guardado, mas não manda imagem. Continuo tentando.", .erro)
            case .success(let nova):
                do {
                    try armazenamento.atualizar(camera.id) {
                        $0.host = nova.host
                        $0.usuario = nova.usuario
                        $0.hash = nova.hash
                    }
                } catch {
                    avisar("Não consegui guardar os dados novos de \(camera.nome): \(error.localizedDescription)", .erro)
                    return
                }
                recarregarCameras()
                reabrirSessoes(de: camera.id)
                avisar(nova.host == camera.host ? "\(camera.nome) tinha trocado de senha: já peguei a nova."
                                                : "\(camera.nome) tinha mudado de endereço na rede: já atualizei.", .ok)
            }
        }
    }

    /// Fecha e reabre só as sessões de uma câmera (os dados dela mudaram); as outras seguem como estão.
    private func reabrirSessoes(de id: String) {
        sessoesGerais.removeValue(forKey: id)?.parar()
        if sessaoDaCamera?.camera.id == id {
            sessaoDaCamera?.encerrar()
            sessaoDaCamera = nil
        }
        ajustarSessoes()
    }

    // MARK: - Avisos

    public func avisar(_ texto: String, _ tipo: Aviso.Tipo = .info, arquivo: URL? = nil) {
        Depuracao.registrar("aviso (\(tipo)): \(texto)")
        let novo = Aviso(texto: texto, tipo: tipo, arquivo: arquivo)
        aviso = novo
        Task {
            try? await Task.sleep(for: .seconds(tipo == .erro ? 6 : 3.5))
            if aviso?.id == novo.id { aviso = nil }
        }
    }

    // MARK: - Argumentos (para abrir direto num estado, útil em testes)

    private func argumentoNumerico(_ nome: String) -> Double? {
        argumentos.firstIndex(of: nome).flatMap { $0 + 1 < argumentos.count ? Double(argumentos[$0 + 1]) : nil }
    }

    private func aplicarArgumentos() {
        let a = argumentos
        func valor(_ nome: String) -> String? { a.firstIndex(of: nome).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        if let q = valor("--qualidade") { qualidadeHD = q != "leve" }
        if let n = valor("--abrir"),
           let c = cameras.first(where: { $0.nome.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                                            == n.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) }) {
            selecao = .camera(c.id)
        }
    }
}
