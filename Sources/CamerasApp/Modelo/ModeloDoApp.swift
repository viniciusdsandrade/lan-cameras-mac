import SwiftUI
import AppKit
import CamerasCore

struct Aviso: Identifiable, Equatable {
    enum Tipo { case info, ok, erro }
    let id = UUID()
    let texto: String
    let tipo: Tipo
    /// Arquivo gerado (uma foto, por exemplo), para o aviso oferecer "Mostrar no Finder".
    var arquivo: URL? = nil
}

@MainActor
final class ModeloDoApp: ObservableObject {
    enum Selecao: Hashable {
        case geral
        case camera(String)
    }

    @Published private(set) var cameras: [CameraConfig] = []
    @Published private(set) var selecao: Selecao = .geral
    /// Visão geral: um fluxo leve (secundário) por câmera.
    @Published private(set) var sessoesGerais: [String: SessaoDeVideo] = [:]
    /// Tela de uma câmera: vídeo, estado e controles.
    @Published private(set) var sessaoDaCamera: SessaoDaCamera?
    @Published var aviso: Aviso?
    @Published private(set) var procurando = false

    // Preferências do usuário
    @AppStorage("qualidadeHD") var qualidadeHD = true
    @AppStorage("mostrarLenteFixa") var mostrarLenteFixa = true
    @AppStorage("velocidade") var velocidade = 0.4
    @AppStorage("volume") var volume = 30.0

    let armazenamento = ArmazenamentoDeCameras()
    private var pausado = false
    private var observadores: [NSObjectProtocol] = []
    private var pausaAgendada: Task<Void, Never>?

    init() {
        recarregarCameras()
        aplicarArgumentosDeLinhaDeComando()
        ajustarSessoes()
        observarCicloDeVida()
    }

    // MARK: - Câmeras

    func recarregarCameras() {
        cameras = (try? armazenamento.carregar()) ?? []
    }

    func camera(id: String) -> CameraConfig? { cameras.first { $0.id == id } }

    func renomear(_ camera: CameraConfig, para nome: String) {
        let limpo = nome.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpo.isEmpty else { return }
        try? armazenamento.atualizar(camera.id) { $0.nome = limpo }
        recarregarCameras()
    }

    // MARK: - Seleção e sessões

    func selecionar(_ nova: Selecao) {
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

    /// Libera todas as sessões (janela escondida, Mac dormindo) sem perder a seleção.
    func pausar() {
        guard !pausado else { return }
        pausado = true
        for s in sessoesGerais.values { s.parar() }
        sessoesGerais = [:]
        sessaoDaCamera?.encerrar()
        sessaoDaCamera = nil
    }

    func retomar() {
        guard pausado else { return }
        pausado = false
        ajustarSessoes()
    }

    func recomecarSessaoDaCamera() {
        guard case .camera = selecao else { return }
        sessaoDaCamera?.encerrar()
        sessaoDaCamera = nil
        ajustarSessoes()
    }

    // MARK: - Cadastro

    /// Acha as câmeras da rede e guarda as novas (as que já existem mantêm nome e ordem).
    func procurarCameras() {
        guard !procurando else { return }
        procurando = true
        avisar("Procurando câmeras na rede…")
        Task {
            let r = await Task.detached(priority: .userInitiated) { () -> Result<Cadastro.Resultado, Error> in
                Result { try Cadastro.procurar(duracao: 4) }
            }.value
            procurando = false
            switch r {
            case .failure(let erro):
                avisar("Não consegui procurar: \(Redact.texto(String(describing: erro)))", .erro)
            case .success(let achado):
                guardar(achado.cameras, falhas: achado.falhas)
            }
        }
    }

    func adicionarPorEndereco(_ texto: String) {
        guard let host = Cadastro.enderecoValido(texto) else {
            avisar("Esse endereço não parece válido. Use o endereço IP da câmera: quatro números separados por pontos.", .erro)
            return
        }
        guard !procurando else { return }
        procurando = true
        Task {
            let r = await Task.detached(priority: .userInitiated) { () -> Result<CameraConfig, Error> in
                Result { try Cadastro.identificar(host: host, nome: "Câmera") }
            }.value
            procurando = false
            switch r {
            case .failure(let erro): avisar("Não achei uma câmera nesse endereço: \(Redact.texto(String(describing: erro)))", .erro)
            case .success(let c): guardar([c], falhas: [])
            }
        }
    }

    private func guardar(_ novas: [CameraConfig], falhas: [String]) {
        guard !novas.isEmpty else {
            avisar(falhas.isEmpty ? "Nenhuma câmera respondeu. Confira se este Mac está no mesmo Wi-Fi que elas." : "Achei aparelhos, mas não consegui identificá-los.", .erro)
            return
        }
        do { try armazenamento.mesclar(novas) }
        catch { avisar("Não consegui guardar as câmeras: \(error.localizedDescription)", .erro); return }
        recarregarCameras()
        reiniciarSessoes()
        avisar(novas.count == 1 ? "Câmera guardada." : "Guardei \(novas.count) câmeras.", .ok)
    }

    /// Fecha e reabre os fluxos (depois de o endereço de uma câmera mudar, por exemplo).
    func reiniciarSessoes() {
        for s in sessoesGerais.values { s.parar() }
        sessoesGerais = [:]
        sessaoDaCamera?.encerrar()
        sessaoDaCamera = nil
        ajustarSessoes()
    }

    func pararTodas() {
        let todas = cameras
        Task {
            let erros = await Task.detached(priority: .userInitiated) { MovimentoPTZ.pararTodas(todas) }.value
            if erros.isEmpty { avisar("Todas as câmeras paradas", .ok) }
            else { avisar(erros.map(Redact.texto).joined(separator: "; "), .erro) }
        }
    }

    // MARK: - Ciclo de vida: não prender as câmeras quando ninguém está olhando

    private func observarCicloDeVida() {
        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        func quando(_ centro: NotificationCenter, _ nome: Notification.Name, _ acao: @escaping @MainActor (ModeloDoApp, Notification) -> Void) {
            observadores.append(centro.addObserver(forName: nome, object: nil, queue: .main) { [weak self] recebida in
                nonisolated(unsafe) let n = recebida                  // chega na thread principal; Notification não é Sendable
                MainActor.assumeIsolated { if let self { acao(self, n) } }
            })
        }
        quando(ws, NSWorkspace.willSleepNotification) { m, _ in m.pausar() }
        quando(ws, NSWorkspace.screensDidSleepNotification) { m, _ in m.pausar() }
        quando(ws, NSWorkspace.didWakeNotification) { m, _ in m.retomarDepois(segundos: 3) }       // dá tempo ao Wi-Fi de voltar
        quando(ws, NSWorkspace.screensDidWakeNotification) { m, _ in m.retomarDepois(segundos: 1) }
        quando(nc, NSApplication.willTerminateNotification) { m, _ in m.sessaoDaCamera?.encerrar() }
        quando(nc, NSWindow.didChangeOcclusionStateNotification) { m, n in
            guard let w = n.object as? NSWindow, w.canBecomeMain else { return }
            if w.occlusionState.contains(.visible) { m.retomarDepois(segundos: 0) } else { m.pausarDepois(segundos: 3) }
        }
    }

    private func pausarDepois(segundos: Double) {
        pausaAgendada?.cancel()
        pausaAgendada = Task {
            try? await Task.sleep(for: .seconds(segundos))
            if !Task.isCancelled { pausar() }
        }
    }

    private func retomarDepois(segundos: Double) {
        pausaAgendada?.cancel()
        pausaAgendada = Task {
            if segundos > 0 { try? await Task.sleep(for: .seconds(segundos)) }
            if !Task.isCancelled { retomar() }
        }
    }

    // MARK: - Avisos

    func avisar(_ texto: String, _ tipo: Aviso.Tipo = .info, arquivo: URL? = nil) {
        let novo = Aviso(texto: texto, tipo: tipo, arquivo: arquivo)
        aviso = novo
        Task {
            try? await Task.sleep(for: .seconds(tipo == .erro ? 6 : 3.5))
            if aviso?.id == novo.id { aviso = nil }
        }
    }

    // MARK: - Linha de comando (para abrir direto num estado, útil em testes)

    private func argumentoNumerico(_ nome: String) -> Double? {
        let a = ProcessInfo.processInfo.arguments
        return a.firstIndex(of: nome).flatMap { $0 + 1 < a.count ? Double(a[$0 + 1]) : nil }
    }

    private func aplicarArgumentosDeLinhaDeComando() {
        let a = ProcessInfo.processInfo.arguments
        func valor(_ nome: String) -> String? { a.firstIndex(of: nome).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        if let q = valor("--qualidade") { qualidadeHD = q != "leve" }
        if let n = valor("--abrir"),
           let c = cameras.first(where: { $0.nome.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                                            == n.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) }) {
            selecao = .camera(c.id)
        }
    }
}
