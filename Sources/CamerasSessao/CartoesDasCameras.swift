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

/// A vez de cada câmera: uma conversa de cada vez com ela, para buscar gravações, ler o cartão, baixar fotos e os
/// pedaços da fita (elas aguentam poucas conexões e, gravando o tempo todo, demoram a responder a mais de uma).
actor VezDaCamera {
    private var ocupada = false
    private var esperando: [(prioridade: Bool, continuacao: CheckedContinuation<Void, Never>)] = []

    /// `prioridade`: passa na frente de quem espera sem ela (o vídeo que alguém está assistindo não espera as fotos
    /// da galeria); entre os de mesma prioridade, a ordem de chegada.
    func pegar(prioridade: Bool = false) async {
        guard ocupada else { ocupada = true; return }
        await withCheckedContinuation { c in
            if prioridade, let i = esperando.firstIndex(where: { !$0.prioridade }) {
                esperando.insert((true, c), at: i)
            } else {
                esperando.append((prioridade, c))
            }
        }
    }

    func soltar() {
        if esperando.isEmpty { ocupada = false } else { esperando.removeFirst().continuacao.resume() }
    }
}

/// As gravações que as câmeras fazem sozinhas no cartão de memória, com o Mac e o celular desligados: por
/// movimento (é o que o app do fabricante configura nelas) ou o tempo todo. Os movimentos de cada noite, de uma
/// câmera ou de todas, com a foto do instante, para assistir e guardar; o que cada câmera tem gravado no
/// período (a cobertura, com os buracos); e a fita, que toca o cartão a partir de qualquer momento.
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
        /// Só o trecho de uma gravação entre duas horas; recebe os bytes já recebidos (devolver false cancela).
        public var baixarTrecho: @Sendable (CameraConfig, GravacaoDoCartao, Date, Date, @escaping @Sendable (Int) -> Bool) throws -> [UInt8]
        /// Liga ou desliga a gravação o tempo todo no cartão.
        public var definirContinua: @Sendable (CameraConfig, Bool) throws -> Void
        /// O quadro de referência de um instante de uma gravação (para o vídeo acompanhar o arrasto da régua).
        public var baixarQuadro: @Sendable (CameraConfig, GravacaoDoCartao, Date) throws -> [UInt8]

        public init(estado: @escaping @Sendable (CameraConfig) throws -> EstadoDoCartao,
                    eventos: @escaping @Sendable (CameraConfig, Date, Date) throws -> (videos: [GravacaoDoCartao], fotos: [GravacaoDoCartao]),
                    baixar: @escaping @Sendable (CameraConfig, GravacaoDoCartao, @escaping @Sendable (Double) -> Bool) throws -> [UInt8],
                    baixarFoto: @escaping @Sendable (CameraConfig, GravacaoDoCartao) throws -> Data,
                    converter: @escaping @Sendable ([UInt8], URL) async throws -> Void,
                    baixarTrecho: @escaping @Sendable (CameraConfig, GravacaoDoCartao, Date, Date, @escaping @Sendable (Int) -> Bool) throws -> [UInt8]
                        = { _, _, _, _, _ in throw DVRIPErro("esta fonte não baixa trechos") },
                    definirContinua: @escaping @Sendable (CameraConfig, Bool) throws -> Void
                        = { _, _ in throw DVRIPErro("esta fonte não muda a gravação") },
                    baixarQuadro: @escaping @Sendable (CameraConfig, GravacaoDoCartao, Date) throws -> [UInt8]
                        = { _, _, _ in throw DVRIPErro("esta fonte não baixa quadros") }) {
            self.estado = estado
            self.eventos = eventos
            self.baixar = baixar
            self.baixarFoto = baixarFoto
            self.converter = converter
            self.baixarTrecho = baixarTrecho
            self.definirContinua = definirContinua
            self.baixarQuadro = baixarQuadro
        }

        public static let cameras = Fonte(
            estado: { try CartaoDaCamera(camera: $0).estado() },
            eventos: { try CartaoDaCamera(camera: $0).eventos(de: $1, ate: $2) },
            baixar: { c, g, progresso in try CartaoDaCamera(camera: c).baixar(g, progresso: progresso) },
            baixarFoto: { try CartaoDaCamera(camera: $0).baixarFoto($1) },
            converter: { _ = try await ConversorDoCartao.converter($0, para: $1) },
            baixarTrecho: { c, g, de, ate, continuar in try CartaoDaCamera(camera: c).baixarTrecho(g, de: de, ate: ate, continuar: continuar) },
            definirContinua: { try CartaoDaCamera(camera: $0).definirGravacaoContinua($1) },
            baixarQuadro: { c, g, instante in try CartaoDaCamera(camera: c).quadroDeReferencia(g, em: instante) })
    }

    /// A câmera escolhida; nil: todas.
    @Published public var camera: String? { didSet { if camera != oldValue { recarregarEventos() } } }
    /// O dia em que a noite começa (ou o dia inteiro, conforme o período). Trocar de dia tira a fita da tela.
    @Published public var dia: Date {
        didSet {
            guard !Calendar.current.isDate(dia, inSameDayAs: oldValue) else { return }
            pararFita()
            recarregarEventos()
        }
    }
    @Published public var periodo: Periodo = .noite {
        didSet {
            guard periodo != oldValue else { return }
            if !mudandoPeriodoSozinho { periodoAutomatico = false }
            let recente = maisRecente()
            if Calendar.current.isDate(dia, inSameDayAs: recente) { recarregarEventos() } else { dia = recente }
        }
    }
    @Published public private(set) var estados: [String: Carga<EstadoDoCartao>] = [:]
    /// Os eventos do período, do mais novo para o mais antigo.
    @Published public private(set) var eventos: Carga<[EventoDoCartao]> = .lendo
    /// Câmeras que não responderam na última busca, com o motivo (as outras aparecem normalmente).
    @Published public private(set) var falhas: [String: String] = [:]
    /// O movimento escolhido (com a fita tocando, o último de onde ela partiu). Escolher um tira os cartões da tela.
    @Published public var selecionado: String? {
        didSet {
            if !escolhendoSozinho { selecaoAutomatica = false }
            guard selecionado != nil else { return }
            mostrandoCartoes = false
        }
    }
    /// Câmeras cujas gravações ainda estão sendo buscadas (cada uma aparece assim que responde).
    @Published public private(set) var buscando: Set<String> = []
    /// Os movimentos do período juntos em períodos de atividade, do mais novo para o mais antigo.
    @Published public private(set) var periodos: [PeriodoDeAtividade] = []
    /// O período que a fita está tocando agora (muda quando ela entra em outro).
    @Published public private(set) var periodoTocando: String?
    /// A pessoa pediu para ver os cartões das câmeras: nenhum movimento é escolhido sozinho enquanto isso.
    @Published public private(set) var mostrandoCartoes = false
    /// Todas as gravações de vídeo do período, de cada câmera (as contínuas também), da mais antiga para a mais nova.
    @Published public private(set) var gravacoes: [String: [GravacaoDoCartao]] = [:]
    /// O que cada câmera tem gravado no período, e os buracos.
    @Published public private(set) var coberturas: [String: CoberturaDoCartao] = [:]
    /// A fita tocando: o cartão de uma câmera a partir de um momento escolhido na linha do tempo.
    @Published public private(set) var fita: FitaDoCartao?
    /// Câmeras em que a gravação contínua está sendo ligada ou desligada.
    @Published public private(set) var mudandoContinua: Set<String> = []
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
    /// Ninguém escolheu o período ainda: com a gravação contínua ligada, o dia todo mostra mais que a noite.
    private var periodoAutomatico = true
    private var mudandoPeriodoSozinho = false
    /// Uma fita pedida antes de as gravações chegarem (pelos argumentos, para testes e capturas de tela).
    private var fitaPedida: (camera: String, instante: Date, velocidade: Float, arrastar: TimeInterval?)?
    /// A fita que estava tocando quando o app soltou as câmeras (janela escondida, Mac dormindo): volta no mesmo
    /// segundo quando ele as retoma.
    private var fitaGuardada: (camera: String, instante: Date, tocando: Bool, velocidade: Float)?
    /// O movimento escolhido foi o app que escolheu (o mais novo, ao abrir): uma busca nova pode trocá-lo.
    private var selecaoAutomatica = true
    private var escolhendoSozinho = false
    /// Acompanha a hora da fita, para saber em que período ela está.
    private var observacaoDaFita: AnyCancellable?

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
        for c in modelo?.cameras ?? [] { recarregarEstado(c) }
    }

    /// A vez de uma câmera (uma conversa de cada vez com ela).
    private func vez(_ id: String) -> VezDaCamera {
        if let v = vezes[id] { return v }
        let v = VezDaCamera()
        vezes[id] = v
        return v
    }

    private func recarregarEstado(_ c: CameraConfig) {
        let fonte = self.fonte
        let vez = self.vez(c.id)
        estados[c.id] = .lendo
        Task {
            await vez.pegar()
            let r = await Task.detached(priority: .userInitiated) { Result { try fonte.estado(c) } }.value
            await vez.soltar()
            switch r {
            case .success(let e):
                estados[c.id] = .pronto(e)
                if e.gravaSempre == true, periodoAutomatico, periodo == .noite {
                    mudandoPeriodoSozinho = true
                    periodo = .diaTodo
                    mudandoPeriodoSozinho = false
                }
            case .failure(let erro): estados[c.id] = .erro(Redact.texto(String(describing: erro)))
            }
        }
    }

    /// Liga ou desliga a gravação o tempo todo no cartão de uma câmera e lê o estado dela de novo.
    public func definirGravacaoContinua(_ id: String, ligada: Bool) {
        guard let c = camera(id: id), !mudandoContinua.contains(id) else { return }
        mudandoContinua.insert(id)
        let fonte = self.fonte
        Task {
            let r = await Task.detached(priority: .userInitiated) { Result { try fonte.definirContinua(c, ligada) } }.value
            mudandoContinua.remove(id)
            switch r {
            case .success:
                modelo?.avisar(ligada ? "\(c.nome) agora grava o tempo todo no cartão." : "\(c.nome) volta a gravar só quando há movimento.", .ok)
            case .failure(let erro):
                modelo?.avisar("Não consegui mudar a gravação de \(c.nome): \(Redact.texto(String(describing: erro)))", .erro)
            }
            recarregarEstado(c)
        }
    }

    public func recarregarEventos() {
        geracao += 1
        let minha = geracao
        let cameras = camerasDoFiltro
        guard !cameras.isEmpty else {
            eventos = .pronto([])
            periodos = []
            falhas = [:]
            gravacoes = [:]
            coberturas = [:]
            buscando = []
            return
        }
        eventos = .lendo
        buscando = Set(cameras.map(\.id))
        let (de, ate) = intervalo()
        let fonte = self.fonte
        let comVez = cameras.map { ($0, vez($0.id)) }
        Task {
            var juntos: [EventoDoCartao] = []
            var todas: [String: [GravacaoDoCartao]] = [:]
            var erros: [String: String] = [:]
            await withTaskGroup(of: (String, Result<(eventos: [EventoDoCartao], videos: [GravacaoDoCartao]), Error>).self) { grupo in
                for (c, vez) in comVez {
                    grupo.addTask {
                        await vez.pegar()
                        let r = Result { try Self.buscar(c, de: de, ate: ate, fonte: fonte) }
                        await vez.soltar()
                        return (c.id, r)
                    }
                }
                // cada câmera aparece assim que responde: a mais lenta não segura as outras
                for await (id, r) in grupo {
                    switch r {
                    case .success(let lido):
                        juntos += lido.eventos
                        todas[id] = lido.videos.sorted { $0.inicio < $1.inicio }
                    case .failure(let erro): erros[id] = Redact.texto(String(describing: erro))
                    }
                    guard minha == geracao else { continue }
                    buscando.remove(id)
                    publicar(juntos, todas, erros, cameras: cameras.count)
                }
            }
        }
    }

    /// Mostra o que as câmeras já mandaram. Enquanto nenhuma tem movimento e ainda há câmeras respondendo, a
    /// galeria segue "procurando" (as faixas da linha do tempo já aparecem).
    private func publicar(_ juntos: [EventoDoCartao], _ todas: [String: [GravacaoDoCartao]], _ erros: [String: String], cameras: Int) {
        let final = buscando.isEmpty
        falhas = erros
        gravacoes = todas
        coberturas = todas.mapValues { CoberturaDoCartao($0) }
        if final, juntos.isEmpty, todas.values.allSatisfy(\.isEmpty), erros.count == cameras, let erro = erros.values.first {
            eventos = .erro(erro)
            return
        }
        guard final || !juntos.isEmpty else { return }
        let lista = juntos.sorted { $0.inicio > $1.inicio }
        periodos = PeriodoDeAtividade.agrupar(lista)
        eventos = .pronto(lista)
        if let f = fita { atualizarPeriodoTocando(f.agora) }
        if let pedida = fitaPedida, todas[pedida.camera] != nil {
            fitaPedida = nil
            tocarFita(camera: pedida.camera, em: pedida.instante)
            fita?.velocidade = pedida.velocidade
            if let deslocamento = pedida.arrastar {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    await self?.ensaiarArrasto(deslocamento)
                }
            }
        }
        // o período mais novo, enquanto ninguém escolheu outro (uma câmera que responde depois pode ter um mais novo)
        if fita == nil, !mostrandoCartoes, selecaoAutomatica || !lista.contains(where: { $0.id == selecionado }) {
            escolhendoSozinho = true
            selecionado = periodos.first?.id
            escolhendoSozinho = false
            selecaoAutomatica = true
        }
        let ids = Set(lista.map(\.id))
        fotos = fotos.filter { ids.contains($0.key) }
    }

    /// As gravações de uma câmera no período, numa conversa com ela: os movimentos (com a foto de cada um) e todos os
    /// vídeos. A busca acha as gravações que COMEÇAM no período: com uma folga, entra também a que já estava
    /// gravando quando ele começou (os arquivos contínuos têm 5 min). A câmera que demorou a responder uma vez
    /// costuma responder na segunda.
    nonisolated private static func buscar(_ c: CameraConfig, de: Date, ate: Date, fonte: Fonte) throws
        -> (eventos: [EventoDoCartao], videos: [GravacaoDoCartao]) {
        let r: (videos: [GravacaoDoCartao], fotos: [GravacaoDoCartao])
        do {
            r = try fonte.eventos(c, de.addingTimeInterval(-folgaDaBusca), ate)
        } catch let e as DVRIPErro where e.deRede {
            r = try fonte.eventos(c, de.addingTimeInterval(-folgaDaBusca), ate)
        }
        // a galeria é dos movimentos do período; as gravações contínuas viram a cobertura da linha do tempo
        let movimentos = r.videos.filter { $0.motivo != .continua && $0.inicio >= de }
        return (EventoDoCartao.juntar(movimentos, r.fotos, camera: c), r.videos)
    }

    // MARK: - Fita

    /// Toca o cartão de uma câmera a partir de `instante`, emendando as gravações (num buraco, começa na
    /// seguinte). Devolve false se não há nada gravado dali em diante no período. `manterSelecao`: o movimento
    /// escolhido segue escolhido (a fita partiu dele); senão, nenhum fica. A velocidade da fita anterior continua.
    /// Na mesma câmera, um instante que a fita já baixou é na hora; senão a fita recomeça lá, mostrando `previa`
    /// (o quadro do arrasto) enquanto baixa.
    @discardableResult
    public func tocarFita(camera id: String, em instante: Date, manterSelecao: Bool = false, previa: CGImage? = nil) -> Bool {
        if let f = fita, f.camera.id == id, f.irPara(instante) {
            if !manterSelecao { selecionado = nil }
            mostrandoCartoes = false
            return true
        }
        guard let c = camera(id: id), let lista = gravacoes[id], lista.contains(where: { $0.fim > instante }) else { return false }
        let velocidade = fita?.velocidade ?? 1
        let previasGuardadas = fita?.camera.id == id ? (fita?.previasGuardadas ?? []) : []   // os quadros já pedidos seguem valendo
        pararFita()
        if !manterSelecao { selecionado = nil }
        mostrandoCartoes = false
        let fonte = self.fonte
        let f = FitaDoCartao(camera: c, desde: instante, arquivos: lista, pasta: pastaDeCache.appendingPathComponent("trechos", isDirectory: true),
                             reproduzir: reproduzirFita, vez: vez(id), previa: previa, previasGuardadas: previasGuardadas,
                             baixar: { g, de, ate, continuar in try fonte.baixarTrecho(c, g, de, ate, continuar) },
                             converter: fonte.converter,
                             buscarMais: { de in try fonte.eventos(c, de, de.addingTimeInterval(6 * 3600)).videos },
                             quadro: { g, t in try fonte.baixarQuadro(c, g, t) },
                             imagemDoQuadro: imagemDoQuadro)
        f.velocidade = velocidade
        fita = f
        // a hora da fita muda no main (ela é do MainActor): em que período ela está
        observacaoDaFita = f.$agora.removeDuplicates().sink { [weak self] agora in
            MainActor.assumeIsolated { self?.atualizarPeriodoTocando(agora) }
        }
        f.iniciar()
        return true
    }

    private func atualizarPeriodoTocando(_ agora: Date) {
        guard let f = fita else { return periodoTocando = nil }
        let id = periodos.first { $0.idDaCamera == f.camera.id && $0.contem(agora) }?.id
        if id != periodoTocando { periodoTocando = id }
    }

    /// O período em que está o movimento escolhido.
    public var periodoSelecionado: PeriodoDeAtividade? {
        guard let selecionado else { return nil }
        return periodos.first { p in p.eventos.contains { $0.id == selecionado } }
    }

    /// Assiste a partir do começo de um período, sem parar.
    @discardableResult
    public func assistir(_ p: PeriodoDeAtividade) -> Bool {
        assistirDesde(p.eventos[0])
    }

    /// Com a fita tocando, vai ao período seguinte (ou ao anterior, ou ao começo do atual) da câmera dela, a partir de
    /// onde ela está; sem fita, escolhe o período seguinte (ou o anterior) da lista.
    public func irAoPeriodo(seguinte: Bool) {
        if let f = fita {
            let daCamera = periodos.filter { $0.idDaCamera == f.camera.id }
            let alvo = seguinte
                ? daCamera.filter { $0.inicio > f.agora.addingTimeInterval(1) }.min { $0.inicio < $1.inicio }
                : daCamera.filter { $0.inicio < f.agora.addingTimeInterval(-3) }.max { $0.inicio < $1.inicio }
            if let alvo { assistir(alvo) }
            return
        }
        guard let atual = periodoSelecionado, let i = periodos.firstIndex(of: atual) else {
            selecionado = periodos.first?.id
            return
        }
        let j = seguinte ? i - 1 : i + 1                         // a lista vai do mais novo para o mais antigo
        if periodos.indices.contains(j) { selecionado = periodos[j].id }
    }

    /// O movimento de uma câmera que estava acontecendo num instante (para guardar o que a fita está mostrando).
    public func movimento(em instante: Date, camera id: String) -> EventoDoCartao? {
        lista.first { $0.idDaCamera == id && $0.inicio <= instante && instante <= $0.gravacao.fim }
    }

    /// Assiste a partir de um movimento, sem parar: o vídeo segue depois dele (com a gravação contínua ligada, o que
    /// veio depois; sem ela, o movimento seguinte).
    @discardableResult
    public func assistirDesde(_ e: EventoDoCartao) -> Bool {
        selecionado = e.id
        return tocarFita(camera: e.idDaCamera, em: e.inicio, manterSelecao: true)
    }

    /// Com a fita tocando, vai ao movimento seguinte (ou ao anterior) da câmera dela, a partir de onde ela está; sem
    /// fita, escolhe o movimento seguinte (ou o anterior) da galeria.
    public func irAoMovimento(seguinte: Bool) {
        guard let f = fita else { return seguinte ? selecionarMaisNovo() : selecionarMaisAntigo() }
        let daCamera = lista.filter { $0.idDaCamera == f.camera.id }
        let alvo = seguinte
            ? daCamera.filter { $0.inicio > f.agora.addingTimeInterval(1) }.min { $0.inicio < $1.inicio }
            : daCamera.filter { $0.inicio < f.agora.addingTimeInterval(-3) }.max { $0.inicio < $1.inicio }
        if let alvo { assistirDesde(alvo) }
    }

    /// Anda `segundos` na fita (para trás, se negativo): no que já foi baixado é na hora; fora disso, a fita recomeça
    /// no destino.
    public func pularFita(_ segundos: TimeInterval) {
        guard let f = fita else { return }
        let destino = f.agora.addingTimeInterval(segundos)
        if f.irPara(destino) { return }
        let querTocar = f.querTocar
        if tocarFita(camera: f.camera.id, em: destino, manterSelecao: true), !querTocar { fita?.pausar() }
    }

    /// O arrasto da régua do tempo passou por um instante: o vídeo vai até lá (no que já foi baixado) ou mostra o
    /// quadro dele (pedido à câmera).
    public func arrastarFita(para instante: Date) {
        fita?.arrastar(para: instante)
    }

    /// Soltou a régua: no que já foi baixado, a fita segue dali na hora; fora disso, recomeça lá, com o quadro do
    /// arrasto na tela enquanto baixa.
    public func soltarFita(em instante: Date) {
        guard let f = fita, !f.soltar(em: instante) else { return }
        let previa = f.previa, querTocar = f.querTocar
        if tocarFita(camera: f.camera.id, em: instante, manterSelecao: true, previa: previa), !querTocar { fita?.pausar() }
    }

    /// Como um quadro vira imagem (os testes trocam: os vídeos deles não são de verdade).
    var imagemDoQuadro: @Sendable ([UInt8]) -> CGImage? = { QuadroDoCartao.imagem(de: $0) }

    /// O app soltou as câmeras (janela escondida, Mac dormindo): guarda onde a fita estava e a tira da tela.
    func pausarFita() {
        guard let f = fita else { return }
        fitaGuardada = (f.camera.id, f.agora, f.querTocar, f.velocidade)
        f.parar()
        fita = nil
        observacaoDaFita = nil
        periodoTocando = nil
    }

    /// O app retomou as câmeras: a fita volta no mesmo segundo, tocando ou pausada como estava.
    func retomarFita() {
        guard let g = fitaGuardada else { return }
        fitaGuardada = nil
        guard tocarFita(camera: g.camera, em: g.instante, manterSelecao: true), let f = fita else { return }
        f.velocidade = g.velocidade
        if !g.tocando { f.pausar() }
    }

    /// Quanto antes do período a busca começa, para pegar a gravação que já estava em curso.
    nonisolated static let folgaDaBusca: TimeInterval = 600

    /// Mostra os cartões das câmeras (espaço, quantos dias guardam, gravar o tempo todo) no lugar do movimento.
    public func mostrarCartoes() {
        pararFita()
        selecionado = nil
        mostrandoCartoes = true
    }

    func pedirFita(camera: String, em instante: Date, velocidade: Float = 1, arrastar: TimeInterval? = nil) {
        fitaPedida = (camera, instante, velocidade, arrastar)
    }

    /// Um arrasto de `deslocamento` segundos na régua, em 2 s, e soltar (pelos argumentos, para testar com as câmeras).
    func ensaiarArrasto(_ deslocamento: TimeInterval) async {
        guard let inicio = fita?.agora else { return }
        Depuracao.registrar("ensaio: arrastando \(Int(deslocamento)) s")
        for k in 1...20 {
            arrastarFita(para: inicio.addingTimeInterval(deslocamento * Double(k) / 20))
            try? await Task.sleep(for: .milliseconds(100))
        }
        soltarFita(em: inicio.addingTimeInterval(deslocamento))
        Depuracao.registrar("ensaio: soltou")
    }

    /// Tira a fita da tela e apaga os pedaços dela.
    public func pararFita(_ quem: String = #function, linha: Int = #line, arquivo: String = #fileID) {
        if fita != nil { Depuracao.registrar("fita: parada por \(arquivo):\(linha) \(quem)") }
        fitaGuardada = nil
        fita?.parar()
        fita = nil
        observacaoDaFita = nil
        periodoTocando = nil
    }

    /// Os testes desligam o vídeo de verdade da fita.
    var reproduzirFita = true

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
            let vez = self.vez(c.id)
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

    /// O cache guarda vídeos e fotos por uma semana (e restos de conversões que não acabaram, por uma hora). Os
    /// pedaços da fita só valem enquanto ela toca.
    private func limparCache() {
        let fm = FileManager.default
        if fita == nil { try? fm.removeItem(at: pastaDeCache.appendingPathComponent("trechos", isDirectory: true)) }
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
