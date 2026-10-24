import Foundation
import Combine
import CamerasCore

/// As gravações que as câmeras fazem sozinhas no cartão de memória, por movimento, com o Mac e o
/// celular desligados (é o que o app do fabricante configura nelas). Aqui elas são listadas por
/// noite, assistidas e guardadas como MP4.
@MainActor
public final class CartoesDasCameras: ObservableObject {
    public enum Periodo: String, CaseIterable, Sendable {
        /// Das horas da noite da gravação por movimento (18 h às 6 h, por padrão).
        case noite
        case diaTodo
    }

    /// Algo que vem das câmeras: sendo lido, pronto ou com erro.
    public enum Carga<Valor: Equatable & Sendable>: Equatable, Sendable {
        case lendo
        case pronto(Valor)
        case erro(String)
    }

    /// De onde vêm os cartões: as câmeras (os testes trocam).
    public struct Fonte: Sendable {
        public var estado: @Sendable (CameraConfig) throws -> EstadoDoCartao
        public var gravacoes: @Sendable (CameraConfig, Date, Date) throws -> [GravacaoDoCartao]
        /// O arquivo como está no cartão; o progresso vai de 0 a 1 (devolver false cancela).
        public var baixar: @Sendable (CameraConfig, GravacaoDoCartao, @escaping @Sendable (Double) -> Bool) throws -> [UInt8]
        public var converter: @Sendable ([UInt8], URL) async throws -> Void

        public init(estado: @escaping @Sendable (CameraConfig) throws -> EstadoDoCartao,
                    gravacoes: @escaping @Sendable (CameraConfig, Date, Date) throws -> [GravacaoDoCartao],
                    baixar: @escaping @Sendable (CameraConfig, GravacaoDoCartao, @escaping @Sendable (Double) -> Bool) throws -> [UInt8],
                    converter: @escaping @Sendable ([UInt8], URL) async throws -> Void) {
            self.estado = estado
            self.gravacoes = gravacoes
            self.baixar = baixar
            self.converter = converter
        }

        public static let cameras = Fonte(
            estado: { try CartaoDaCamera(camera: $0).estado() },
            gravacoes: { try CartaoDaCamera(camera: $0).gravacoes(de: $1, ate: $2) },
            baixar: { c, g, progresso in try CartaoDaCamera(camera: c).baixar(g, progresso: progresso) },
            converter: { _ = try await ConversorDoCartao.converter($0, para: $1) })
    }

    /// A câmera escolhida (nil: a primeira).
    @Published public var camera: String? { didSet { if camera != oldValue { recarregarLista() } } }
    /// O dia em que a noite começa (ou o dia inteiro, conforme o período).
    @Published public var dia: Date { didSet { if dia != oldValue { recarregarLista() } } }
    @Published public var periodo: Periodo = .noite { didSet { if periodo != oldValue { recarregarLista() } } }
    @Published public private(set) var estados: [String: Carga<EstadoDoCartao>] = [:]
    /// As gravações do período, da mais nova para a mais antiga.
    @Published public private(set) var lista: Carga<[GravacaoDoCartao]> = .lendo
    /// Gravações sendo baixadas e convertidas, com o progresso de 0 a 1.
    @Published public private(set) var baixando: [String: Double] = [:]

    weak var modelo: ModeloDoApp?
    private let fonte: Fonte
    private let pastaDeCache: URL
    private let pastaDeGravacoes: URL
    private let agora: () -> Date
    /// Só a busca mais recente vale (trocar de câmera ou de dia no meio de uma busca a descarta).
    private var geracao = 0

    init(fonte: Fonte, pastaDeCache: URL, pastaDeGravacoes: URL, agora: @escaping () -> Date) {
        self.fonte = fonte
        self.pastaDeCache = pastaDeCache
        self.pastaDeGravacoes = pastaDeGravacoes
        self.agora = agora
        dia = agora()
    }

    /// As horas da noite: as da gravação por movimento.
    private var horas: (inicio: Int, fim: Int) {
        let a = modelo?.gravacao.ajustes ?? GravacaoPorMovimento.Ajustes()
        return (a.inicio, a.fim)
    }

    public var cameraEscolhida: CameraConfig? {
        let cameras = modelo?.cameras ?? []
        return cameras.first { $0.id == camera } ?? cameras.first
    }

    /// A noite mais recente: a que está acontecendo ou, de dia, a que acabou.
    func noiteMaisRecente() -> Date {
        let cal = Calendar.current
        let hoje = agora()
        return cal.component(.hour, from: hoje) < horas.inicio ? cal.date(byAdding: .day, value: -1, to: hoje)! : hoje
    }

    /// Começo e fim do período escolhido.
    public func intervalo() -> (de: Date, ate: Date) {
        let cal = Calendar.current
        let inicioDoDia = cal.startOfDay(for: dia)
        let amanha = cal.date(byAdding: .day, value: 1, to: inicioDoDia)!
        guard periodo == .noite else { return (inicioDoDia, amanha) }
        let (h0, h1) = horas
        let de = cal.date(bySettingHour: h0, minute: 0, second: 0, of: inicioDoDia)!
        let ate = cal.date(bySettingHour: h1, minute: 0, second: 0, of: h1 > h0 ? inicioDoDia : amanha)!
        return (de, ate)
    }

    /// Ao abrir a tela: a noite mais recente, o estado de cada cartão e a lista da câmera escolhida.
    public func abrir() {
        limparCache()
        let noite = noiteMaisRecente()
        if !Calendar.current.isDate(dia, inSameDayAs: noite) { dia = noite } else { recarregarLista() }
        recarregarEstados()
    }

    public func recarregarEstados() {
        let fonte = self.fonte
        for c in modelo?.cameras ?? [] {
            estados[c.id] = .lendo
            Task {
                let r = await Task.detached(priority: .userInitiated) { Result { try fonte.estado(c) } }.value
                switch r {
                case .success(let e): estados[c.id] = .pronto(e)
                case .failure(let erro): estados[c.id] = .erro(Redact.texto(String(describing: erro)))
                }
            }
        }
    }

    public func recarregarLista() {
        geracao += 1
        let minha = geracao
        guard let c = cameraEscolhida else { lista = .pronto([]); return }
        lista = .lendo
        let (de, ate) = intervalo()
        let fonte = self.fonte
        Task {
            let r = await Task.detached(priority: .userInitiated) { Result { try fonte.gravacoes(c, de, ate) } }.value
            guard minha == geracao else { return }
            switch r {
            case .success(let l): lista = .pronto(l.sorted { $0.inicio > $1.inicio })
            case .failure(let erro): lista = .erro(Redact.texto(String(describing: erro)))
            }
        }
    }

    // MARK: - Assistir e guardar

    /// Baixa e converte a gravação (uma vez: depois, ela fica no cache) e devolve o MP4.
    public func assistir(_ g: GravacaoDoCartao) async -> URL? {
        guard let c = cameraEscolhida else { return nil }
        return await noCache(g, camera: c)
    }

    /// Guarda a gravação junto com as do app (Filmes > Câmeras de Casa, no Mac).
    @discardableResult
    public func guardar(_ g: GravacaoDoCartao) async -> URL? {
        guard let c = cameraEscolhida, let pronto = await noCache(g, camera: c) else { return nil }
        let fm = FileManager.default
        let base = "\(Plataforma.nomeDeArquivo(c.nome))-cartão-\(Plataforma.carimbo(g.inicio))"
        var destino = pastaDeGravacoes.appendingPathComponent(base + ".mp4")
        var n = 2
        while fm.fileExists(atPath: destino.path) {
            destino = pastaDeGravacoes.appendingPathComponent("\(base)-\(n).mp4")
            n += 1
        }
        do {
            try fm.createDirectory(at: pastaDeGravacoes, withIntermediateDirectories: true)
            try fm.copyItem(at: pronto, to: destino)
        } catch {
            modelo?.avisar("Não consegui guardar a gravação: \(error.localizedDescription)", .erro)
            return nil
        }
        modelo?.gravacao.recarregarRecentes()
        modelo?.avisar("Gravação de \(c.nome) guardada em \(Plataforma.ondeFicamAsGravacoes).", .ok, arquivo: destino)
        return destino
    }

    private func arquivoNoCache(_ g: GravacaoDoCartao, camera c: CameraConfig) -> URL {
        pastaDeCache.appendingPathComponent("\(Plataforma.nomeDeArquivo(c.nome))-\(Plataforma.carimbo(g.inicio))-\(g.bytes).mp4")
    }

    private func noCache(_ g: GravacaoDoCartao, camera c: CameraConfig) async -> URL? {
        let destino = arquivoNoCache(g, camera: c)
        if FileManager.default.fileExists(atPath: destino.path) { return destino }
        guard baixando[g.id] == nil else { return nil }                  // já está vindo
        baixando[g.id] = 0
        defer { baixando[g.id] = nil }
        let fonte = self.fonte
        let id = g.id
        let ultimo = Atomico(0.0)
        let parcial = destino.deletingPathExtension().appendingPathExtension("parcial.mp4")
        let mostrar: @Sendable (Double) -> Void = { [weak self] p in
            guard let self else { return }
            Task { @MainActor in
                if self.baixando[id] != nil { self.baixando[id] = 0.95 * p }    // atrasado: já acabou
            }
        }
        do {
            try FileManager.default.createDirectory(at: pastaDeCache, withIntermediateDirectories: true)
            let bytes = try await Task.detached(priority: .userInitiated) {
                try fonte.baixar(c, g) { p in
                    // um aviso a cada 2%: são centenas de pedaços num arquivo grande
                    if p - ultimo.valor >= 0.02 || p >= 1 {
                        ultimo.valor = p
                        mostrar(p)
                    }
                    return true
                }
            }.value
            try await fonte.converter(bytes, parcial)
            try FileManager.default.moveItem(at: parcial, to: destino)
            return destino
        } catch {
            try? FileManager.default.removeItem(at: parcial)
            modelo?.avisar("Não consegui baixar a gravação de \(c.nome): \(Redact.texto(String(describing: error)))", .erro)
            return nil
        }
    }

    /// O cache guarda os vídeos já convertidos por uma semana (e restos de conversões que não acabaram, por uma hora).
    private func limparCache() {
        let fm = FileManager.default
        let semana = agora().addingTimeInterval(-7 * 24 * 3600), hora = agora().addingTimeInterval(-3600)
        let arquivos = (try? fm.contentsOfDirectory(at: pastaDeCache, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for u in arquivos {
            let data = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
            if data < semana || (u.lastPathComponent.hasSuffix(".parcial.mp4") && data < hora) { try? fm.removeItem(at: u) }
        }
    }
}
