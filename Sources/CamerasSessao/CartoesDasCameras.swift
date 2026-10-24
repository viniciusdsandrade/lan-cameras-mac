import Foundation
import Combine
import CoreGraphics
import ImageIO
import CamerasCore

/// Um movimento gravado no cartão de uma câmera: o vídeo e, quando a câmera tirou, a foto do instante
/// em que o movimento foi notado (o vídeo começa uns segundos antes, então a foto mostra melhor o que houve).
public struct EventoDoCartao: Identifiable, Hashable, Sendable {
    public let idDaCamera: String
    public let nomeDaCamera: String
    /// As duas lentes vêm empilhadas na mesma imagem (a fixa em cima, a móvel embaixo).
    public let duasLentes: Bool
    public let gravacao: GravacaoDoCartao
    public let foto: GravacaoDoCartao?

    public init(idDaCamera: String, nomeDaCamera: String, duasLentes: Bool, gravacao: GravacaoDoCartao, foto: GravacaoDoCartao?) {
        self.idDaCamera = idDaCamera
        self.nomeDaCamera = nomeDaCamera
        self.duasLentes = duasLentes
        self.gravacao = gravacao
        self.foto = foto
    }

    public var id: String { "\(idDaCamera)|\(gravacao.id)" }
    public var inicio: Date { gravacao.inicio }

    /// A pré-gravação das câmeras: o movimento foi notado uns 5 s depois do começo do vídeo.
    static let antesDoMovimento = 5.0

    /// Junta cada vídeo à foto tirada durante ele, a mais perto do instante em que o movimento foi notado.
    static func juntar(_ videos: [GravacaoDoCartao], _ fotos: [GravacaoDoCartao], camera: CameraConfig) -> [EventoDoCartao] {
        videos.map { v in
            let alvo = v.inicio.addingTimeInterval(antesDoMovimento)
            let foto = fotos.filter { $0.inicio >= v.inicio.addingTimeInterval(-1) && $0.inicio <= v.fim.addingTimeInterval(1) }
                .min { abs($0.inicio.timeIntervalSince(alvo)) < abs($1.inicio.timeIntervalSince(alvo)) }
            return EventoDoCartao(idDaCamera: camera.id, nomeDaCamera: camera.nome, duasLentes: camera.duasLentes, gravacao: v, foto: foto)
        }
    }
}

/// A vez de cada câmera: uma conversa de cada vez para buscar fotos (elas aguentam poucas conexões).
actor VezDaCamera {
    private var ocupada = false
    private var esperando: [CheckedContinuation<Void, Never>] = []

    func pegar() async {
        guard ocupada else { ocupada = true; return }
        await withCheckedContinuation { esperando.append($0) }
    }

    func soltar() {
        if esperando.isEmpty { ocupada = false } else { esperando.removeFirst().resume() }
    }
}

/// As gravações que as câmeras fazem sozinhas no cartão de memória, por movimento, com o Mac e o
/// celular desligados (é o que o app do fabricante configura nelas): os eventos de cada noite, de
/// uma câmera ou de todas, com a foto do instante, para assistir e guardar.
@MainActor
public final class CartoesDasCameras: ObservableObject {
    public enum Periodo: String, CaseIterable, Sendable {
        /// Das horas da noite da gravação pelo Mac (18 h às 6 h, por padrão).
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
        public var eventos: @Sendable (CameraConfig, Date, Date) throws -> (videos: [GravacaoDoCartao], fotos: [GravacaoDoCartao])
        /// O vídeo como está no cartão; o progresso vai de 0 a 1 (devolver false cancela).
        public var baixar: @Sendable (CameraConfig, GravacaoDoCartao, @escaping @Sendable (Double) -> Bool) throws -> [UInt8]
        /// O JPEG de uma foto do cartão.
        public var baixarFoto: @Sendable (CameraConfig, GravacaoDoCartao) throws -> Data
        public var converter: @Sendable ([UInt8], URL) async throws -> Void

        public init(estado: @escaping @Sendable (CameraConfig) throws -> EstadoDoCartao,
                    eventos: @escaping @Sendable (CameraConfig, Date, Date) throws -> (videos: [GravacaoDoCartao], fotos: [GravacaoDoCartao]),
                    baixar: @escaping @Sendable (CameraConfig, GravacaoDoCartao, @escaping @Sendable (Double) -> Bool) throws -> [UInt8],
                    baixarFoto: @escaping @Sendable (CameraConfig, GravacaoDoCartao) throws -> Data,
                    converter: @escaping @Sendable ([UInt8], URL) async throws -> Void) {
            self.estado = estado
            self.eventos = eventos
            self.baixar = baixar
            self.baixarFoto = baixarFoto
            self.converter = converter
        }

        public static let cameras = Fonte(
            estado: { try CartaoDaCamera(camera: $0).estado() },
            eventos: { try CartaoDaCamera(camera: $0).eventos(de: $1, ate: $2) },
            baixar: { c, g, progresso in try CartaoDaCamera(camera: c).baixar(g, progresso: progresso) },
            baixarFoto: { try CartaoDaCamera(camera: $0).baixarFoto($1) },
            converter: { _ = try await ConversorDoCartao.converter($0, para: $1) })
    }

    /// A câmera escolhida; nil: todas.
    @Published public var camera: String? { didSet { if camera != oldValue { recarregarEventos() } } }
    /// O dia em que a noite começa (ou o dia inteiro, conforme o período).
    @Published public var dia: Date { didSet { if !Calendar.current.isDate(dia, inSameDayAs: oldValue) { recarregarEventos() } } }
    @Published public var periodo: Periodo = .noite {
        didSet {
            guard periodo != oldValue else { return }
            let recente = maisRecente()
            if Calendar.current.isDate(dia, inSameDayAs: recente) { recarregarEventos() } else { dia = recente }
        }
    }
    @Published public private(set) var estados: [String: Carga<EstadoDoCartao>] = [:]
    /// Os eventos do período, do mais novo para o mais antigo.
    @Published public private(set) var eventos: Carga<[EventoDoCartao]> = .lendo
    /// Câmeras que não responderam na última busca, com o motivo (as outras aparecem normalmente).
    @Published public private(set) var falhas: [String: String] = [:]
    @Published public var selecionado: String?
    /// Vídeos sendo baixados e convertidos, com o progresso de 0 a 1.
    @Published public private(set) var baixando: [String: Double] = [:]
    /// As fotos já baixadas, por evento.
    @Published public private(set) var fotos: [String: CGImage] = [:]

    weak var modelo: ModeloDoApp?
    private let fonte: Fonte
    private let pastaDeCache: URL
    private let pastaDeGravacoes: URL
    private let agora: () -> Date
    /// Só a busca mais recente vale (trocar de câmera ou de dia no meio de uma busca a descarta).
    private var geracao = 0
    private var vezes: [String: VezDaCamera] = [:]
    private var buscandoFoto: Set<String> = []

    init(fonte: Fonte, pastaDeCache: URL, pastaDeGravacoes: URL, agora: @escaping () -> Date) {
        self.fonte = fonte
        self.pastaDeCache = pastaDeCache
        self.pastaDeGravacoes = pastaDeGravacoes
        self.agora = agora
        dia = agora()
    }

    // MARK: - Período

    /// As horas da noite: as da gravação pelo Mac.
    private var horas: (inicio: Int, fim: Int) {
        let a = modelo?.gravacao.ajustes ?? GravacaoPorMovimento.Ajustes()
        return (a.inicio, a.fim)
    }

    /// A noite mais recente: a que está acontecendo ou, de dia, a que acabou.
    func noiteMaisRecente() -> Date {
        let cal = Calendar.current
        let hoje = agora()
        return cal.component(.hour, from: hoje) < horas.inicio ? cal.date(byAdding: .day, value: -1, to: hoje)! : hoje
    }

    private func maisRecente() -> Date { periodo == .noite ? noiteMaisRecente() : agora() }

    /// Começo e fim do período de um dia (por padrão, o escolhido).
    public func intervalo(do dia: Date? = nil) -> (de: Date, ate: Date) {
        let cal = Calendar.current
        let inicioDoDia = cal.startOfDay(for: dia ?? self.dia)
        let amanha = cal.date(byAdding: .day, value: 1, to: inicioDoDia)!
        guard periodo == .noite else { return (inicioDoDia, amanha) }
        let (h0, h1) = horas
        let de = cal.date(bySettingHour: h0, minute: 0, second: 0, of: inicioDoDia)!
        let ate = cal.date(bySettingHour: h1, minute: 0, second: 0, of: h1 > h0 ? inicioDoDia : amanha)!
        return (de, ate)
    }

    /// As últimas 7 noites (ou dias), da mais recente para a mais antiga.
    public var diasRecentes: [Date] {
        let recente = maisRecente()
        return (0..<7).map { Calendar.current.date(byAdding: .day, value: -$0, to: recente)! }
    }

    /// "Esta noite", "Noite passada", "Hoje", "Ontem" ou o dia da semana ("qua., 22").
    public func rotulo(do d: Date) -> String {
        let cal = Calendar.current
        let distancia = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: maisRecente())).day ?? 0
        if periodo == .diaTodo {
            if distancia == 0 { return "Hoje" }
            if distancia == 1 { return "Ontem" }
        } else {
            let emCurso = agora() < intervalo(do: maisRecente()).ate
            if distancia == 0 { return emCurso ? "Esta noite" : "Noite passada" }
            if distancia == 1, emCurso { return "Noite passada" }
        }
        return d.formatted(.dateTime.weekday(.abbreviated).day())
    }

    // MARK: - Câmeras e eventos

    private func camera(id: String) -> CameraConfig? { modelo?.cameras.first { $0.id == id } }

    /// As câmeras do filtro: a escolhida ou todas.
    private var camerasDoFiltro: [CameraConfig] {
        let todas = modelo?.cameras ?? []
        guard let camera else { return todas }
        return todas.filter { $0.id == camera }
    }

    /// Ao abrir a tela: o período mais recente, o estado de cada cartão e os eventos.
    public func abrir() {
        limparCache()
        let recente = maisRecente()
        if !Calendar.current.isDate(dia, inSameDayAs: recente) { dia = recente } else { recarregarEventos() }
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

    public func recarregarEventos() {
        geracao += 1
        let minha = geracao
        let cameras = camerasDoFiltro
        guard !cameras.isEmpty else {
            eventos = .pronto([])
            falhas = [:]
            return
        }
        eventos = .lendo
        let (de, ate) = intervalo()
        let fonte = self.fonte
        Task {
            var juntos: [EventoDoCartao] = []
            var erros: [String: String] = [:]
            await withTaskGroup(of: (String, Result<[EventoDoCartao], Error>).self) { grupo in
                for c in cameras {
                    grupo.addTask {
                        (c.id, Result {
                            let r = try fonte.eventos(c, de, ate)
                            return EventoDoCartao.juntar(r.videos, r.fotos, camera: c)
                        })
                    }
                }
                for await (id, r) in grupo {
                    switch r {
                    case .success(let lista): juntos += lista
                    case .failure(let erro): erros[id] = Redact.texto(String(describing: erro))
                    }
                }
            }
            guard minha == geracao else { return }
            falhas = erros
            if juntos.isEmpty, erros.count == cameras.count, let erro = erros.values.first {
                eventos = .erro(erro)
            } else {
                let lista = juntos.sorted { $0.inicio > $1.inicio }
                eventos = .pronto(lista)
                if !lista.contains(where: { $0.id == selecionado }) { selecionado = lista.first?.id }
                let ids = Set(lista.map(\.id))
                fotos = fotos.filter { ids.contains($0.key) }
            }
        }
    }

    private var lista: [EventoDoCartao] {
        if case .pronto(let l) = eventos { return l }
        return []
    }

    public var eventoSelecionado: EventoDoCartao? { lista.first { $0.id == selecionado } }

    /// O evento seguinte no tempo (a lista vai do mais novo para o mais antigo).
    public func selecionarMaisNovo() {
        guard let i = lista.firstIndex(where: { $0.id == selecionado }), i > 0 else { return }
        selecionado = lista[i - 1].id
    }

    public func selecionarMaisAntigo() {
        guard let i = lista.firstIndex(where: { $0.id == selecionado }) else { selecionado = lista.first?.id; return }
        if i + 1 < lista.count { selecionado = lista[i + 1].id }
    }

    // MARK: - Fotos

    /// Baixa (uma vez: depois ela fica no cache) a foto do evento. Quem chama pode cancelar: um
    /// cartão que saiu da tela antes da vez dele não baixa nada.
    public func carregarFoto(_ e: EventoDoCartao) async {
        guard fotos[e.id] == nil, let f = e.foto, let c = camera(id: e.idDaCamera), !buscandoFoto.contains(e.id) else { return }
        buscandoFoto.insert(e.id)
        defer { buscandoFoto.remove(e.id) }
        let arquivo = pastaDeCache.appendingPathComponent("fotos", isDirectory: true)
            .appendingPathComponent("\(Plataforma.nomeDeArquivo(c.nome))-\(Plataforma.carimbo(f.inicio))-\(f.bytes).jpg")
        var dados = try? Data(contentsOf: arquivo)
        if dados == nil {
            let vez = vezes[c.id] ?? VezDaCamera()
            vezes[c.id] = vez
            await vez.pegar()
            if !Task.isCancelled {
                let fonte = self.fonte
                dados = try? await Task.detached(priority: .utility) { try fonte.baixarFoto(c, f) }.value
            }
            await vez.soltar()
            if let dados {
                try? FileManager.default.createDirectory(at: arquivo.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? dados.write(to: arquivo)
            }
        }
        guard let dados, let fonteDaImagem = CGImageSourceCreateWithData(dados as CFData, nil),
              let imagem = CGImageSourceCreateImageAtIndex(fonteDaImagem, 0, nil) else { return }
        fotos[e.id] = imagem
    }

    // MARK: - Assistir e guardar

    /// O vídeo do evento, se já foi baixado e convertido.
    public func videoPronto(_ e: EventoDoCartao) -> URL? {
        guard let c = camera(id: e.idDaCamera) else { return nil }
        let url = arquivoNoCache(e.gravacao, camera: c)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Baixa e converte o vídeo (uma vez: depois ele fica no cache) e devolve o MP4.
    public func assistir(_ e: EventoDoCartao) async -> URL? {
        guard let c = camera(id: e.idDaCamera) else { return nil }
        return await noCache(e, camera: c)
    }

    /// Guarda o vídeo junto com as gravações do app (Filmes > Câmeras de Casa, no Mac).
    @discardableResult
    public func guardar(_ e: EventoDoCartao) async -> URL? {
        guard let c = camera(id: e.idDaCamera), let pronto = await noCache(e, camera: c) else { return nil }
        let fm = FileManager.default
        let base = "\(Plataforma.nomeDeArquivo(c.nome))-cartão-\(Plataforma.carimbo(e.inicio))"
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

    private func noCache(_ e: EventoDoCartao, camera c: CameraConfig) async -> URL? {
        let g = e.gravacao
        let destino = arquivoNoCache(g, camera: c)
        if FileManager.default.fileExists(atPath: destino.path) { return destino }
        let id = e.id
        guard baixando[id] == nil else { return nil }                  // já está vindo
        baixando[id] = 0
        defer { baixando[id] = nil }
        let fonte = self.fonte
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

    /// O cache guarda vídeos e fotos por uma semana (e restos de conversões que não acabaram, por uma hora).
    private func limparCache() {
        let fm = FileManager.default
        let semana = agora().addingTimeInterval(-7 * 24 * 3600), hora = agora().addingTimeInterval(-3600)
        for pasta in [pastaDeCache, pastaDeCache.appendingPathComponent("fotos", isDirectory: true)] {
            let arquivos = (try? fm.contentsOfDirectory(at: pasta, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])) ?? []
            for u in arquivos where (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true {
                let data = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
                if data < semana || (u.lastPathComponent.hasSuffix(".parcial.mp4") && data < hora) { try? fm.removeItem(at: u) }
            }
        }
    }
}
