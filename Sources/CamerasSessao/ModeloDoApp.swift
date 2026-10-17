import SwiftUI
import CamerasCore

/// O estado do app inteiro: câmeras guardadas, o que está na tela, as sessões abertas nas câmeras,
/// avisos e preferências. É o mesmo no Mac e no iPhone; o que muda (janela, segundo plano) fica
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
    /// Sessões soltas porque ninguém está vendo (janela escondida, app em segundo plano, aparelho dormindo).
    private(set) var pausado = false
    var observadores: [NSObjectProtocol] = []
    private var pausaAgendada: Task<Void, Never>?
    private let argumentos: [String]

    /// `argumentos`: `--abrir NOME`, `--qualidade leve|hd`, `--zoom N` abrem direto num estado (útil em testes).
    public init(armazenamento: ArmazenamentoDeCameras = ArmazenamentoDeCameras(),
                argumentos: [String] = ProcessInfo.processInfo.arguments,
                observarCicloDeVida: Bool = true) {
        self.armazenamento = armazenamento
        self.argumentos = argumentos
        recarregarCameras()
        aplicarArgumentos()
        ajustarSessoes()
        if observarCicloDeVida { self.observarCicloDeVida() }
    }

    // MARK: - Câmeras

    public func recarregarCameras() {
        cameras = (try? armazenamento.carregar()) ?? []
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
