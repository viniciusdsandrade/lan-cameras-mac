import Foundation
import Combine
import AVFoundation
import CamerasCore

/// Um arquivo da pasta de gravações.
public struct ArquivoGravado: Identifiable, Equatable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let data: Date
    public let bytes: Int64
    /// Lida do arquivo depois (nil até lá).
    public var duracao: Double?
}

/// Gravação por movimento: com ela ligada, cada câmera escolhida ganha uma vigia que grava
/// enquanto houver movimento, só à noite (por padrão) ou o dia todo.
///
/// Diferente do vídeo da tela, a vigia não para com a janela minimizada ou escondida nem com a tela
/// apagada: é para isso que ela existe. Enquanto alguma vigia roda, o Mac não dorme sozinho (a tela
/// pode apagar) e o sistema não põe o app para cochilar. Fora do horário ela solta as câmeras.
@MainActor
public final class GravacaoPorMovimento: ObservableObject {
    public struct Ajustes: Codable, Equatable, Sendable {
        public var ligada = false
        /// Câmeras que ficam de fora (as que entrarem depois já vêm vigiadas).
        public var deFora: Set<String> = []
        public var soANoite = true
        /// Horas cheias, de 0 a 23, em que a noite começa e termina.
        public var inicio = 18
        public var fim = 6
        public var sensibilidade: SensibilidadeDeMovimento = .media
        public var gravarSom = true
        /// Grava o vídeo principal (HD); senão, o leve.
        public var hd = true

        public init() {}

        /// Se é hora de vigiar. Com início e fim iguais, a noite dura o dia todo.
        public func noHorario(_ data: Date, calendario: Calendar = .current) -> Bool {
            guard soANoite, inicio != fim else { return true }
            let h = calendario.component(.hour, from: data)
            return inicio < fim ? (inicio <= h && h < fim) : (h >= inicio || h < fim)
        }

        // Ajustes guardados por uma versão anterior, com menos campos, ficam com o padrão nos que faltam.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let p = Ajustes()
            ligada = try c.decodeIfPresent(Bool.self, forKey: .ligada) ?? p.ligada
            deFora = try c.decodeIfPresent(Set<String>.self, forKey: .deFora) ?? p.deFora
            soANoite = try c.decodeIfPresent(Bool.self, forKey: .soANoite) ?? p.soANoite
            inicio = try c.decodeIfPresent(Int.self, forKey: .inicio).map { min(23, max(0, $0)) } ?? p.inicio
            fim = try c.decodeIfPresent(Int.self, forKey: .fim).map { min(23, max(0, $0)) } ?? p.fim
            sensibilidade = (try? c.decodeIfPresent(SensibilidadeDeMovimento.self, forKey: .sensibilidade)) ?? p.sensibilidade
            gravarSom = try c.decodeIfPresent(Bool.self, forKey: .gravarSom) ?? p.gravarSom
            hd = try c.decodeIfPresent(Bool.self, forKey: .hd) ?? p.hd
        }
    }

    /// O que a gravação está fazendo com uma câmera.
    public enum Situacao: Hashable, Sendable {
        /// Ligada, mas fora do horário: a câmera está livre.
        case foraDoHorario
        case conectando
        case vigiando
        case gravando
        case erro(String)
    }

    @Published public var ajustes: Ajustes {
        didSet {
            guard ajustes != oldValue else { return }
            do { try armazenamento.salvarAjustesDeGravacao(ajustes) }
            catch { modelo?.avisar("Não consegui guardar os ajustes da gravação: \(error.localizedDescription)", .erro) }
            aplicar()
        }
    }
    /// Só das câmeras que a gravação vigia (ligada e não deixada de fora).
    @Published public private(set) var situacoes: [String: Situacao] = [:]
    @Published public private(set) var recentes: [ArquivoGravado] = []

    public let pasta: URL
    weak var modelo: ModeloDoApp?
    private let armazenamento: ArmazenamentoDeCameras
    private let agora: () -> Date
    private let intervaloDoRelogio: Duration

    private struct Vigilancia {
        let camera: CameraConfig
        let stream: StreamDeVideo
        let ajustes: VigiaDeMovimento.Ajustes
        let vigia: VigiaDeMovimento
    }

    private var cameras: [CameraConfig] = []
    private var vigias: [String: Vigilancia] = [:]
    private var relogio: Task<Void, Never>?
    private var atividade: NSObjectProtocol?

    /// `agora` e `intervaloDoRelogio`: de quanto em quanto tempo confere o horário (os testes trocam).
    init(armazenamento: ArmazenamentoDeCameras, pasta: URL,
         agora: @escaping () -> Date = Date.init, intervaloDoRelogio: Duration = .seconds(30)) {
        self.armazenamento = armazenamento
        self.pasta = pasta
        self.agora = agora
        self.intervaloDoRelogio = intervaloDoRelogio
        ajustes = armazenamento.ajustesDeGravacao(Ajustes.self) ?? Ajustes()
        recarregarRecentes()
    }

    public var gravandoAlguma: Bool { situacoes.values.contains(.gravando) }
    public var vigiando: Bool { !vigias.isEmpty }
    func vigia(de id: String) -> VigiaDeMovimento? { vigias[id]?.vigia }

    public func vigiada(_ id: String) -> Bool { !ajustes.deFora.contains(id) }

    public func definir(_ id: String, vigiada: Bool) {
        if vigiada { ajustes.deFora.remove(id) } else { ajustes.deFora.insert(id) }
    }

    /// As câmeras guardadas mudaram (endereço ou senha novos, câmera nova): ajusta as vigias.
    func atualizar(cameras novas: [CameraConfig]) {
        cameras = novas
        aplicar()
    }

    /// Solta todas as câmeras e espera os arquivos em curso ficarem prontos (o app vai fechar).
    public func encerrar() {
        relogio?.cancel()
        relogio = nil
        let todas = vigias.values.map(\.vigia)
        vigias = [:]
        for v in todas { v.parar() }
        let limite = Date().addingTimeInterval(3)
        for v in todas { v.esperarArquivos(ate: max(0.1, limite.timeIntervalSinceNow)) }
        for v in todas { v.esperarConexao(ate: max(0.1, limite.timeIntervalSinceNow)) }
        manterAcordado(false)
    }

    // MARK: - Vigias

    /// Liga, desliga e reinicia as vigias conforme os ajustes, o horário e as câmeras.
    func aplicar() {
        let noHorario = ajustes.ligada && ajustes.noHorario(agora())
        let stream: StreamDeVideo = ajustes.hd ? .principal : .secundario
        let ajustesDaVigia = VigiaDeMovimento.Ajustes(sensibilidade: ajustes.sensibilidade, gravarSom: ajustes.gravarSom)
        var situacoes: [String: Situacao] = [:]

        for (id, v) in vigias {
            // endereço, senha ou nome novos (o nome vai no nome de cada arquivo): vigia nova
            let atual = cameras.first { $0.id == id }
            let mesma = atual.map { $0.host == v.camera.host && $0.usuario == v.camera.usuario && $0.hash == v.camera.hash
                && $0.nome == v.camera.nome } ?? false
            if !noHorario || !vigiada(id) || !mesma || v.stream != stream || v.ajustes != ajustesDaVigia {
                v.vigia.parar()
                vigias[id] = nil
                Depuracao.registrar("gravação: vigia de \(v.camera.nome) desligada")
            }
        }
        for c in cameras where ajustes.ligada && vigiada(c.id) {
            guard noHorario else {
                situacoes[c.id] = .foraDoHorario
                continue
            }
            if vigias[c.id] == nil { vigias[c.id] = criarVigia(c, stream: stream, ajustes: ajustesDaVigia) }
            situacoes[c.id] = Self.situacao(vigias[c.id]!.vigia.estado)
        }
        self.situacoes = situacoes
        manterAcordado(!vigias.isEmpty)

        if ajustes.ligada, relogio == nil {
            let intervalo = intervaloDoRelogio
            relogio = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: intervalo)
                    if Task.isCancelled { break }
                    self?.aplicar()
                }
            }
        } else if !ajustes.ligada {
            relogio?.cancel()
            relogio = nil
        }
    }

    private func criarVigia(_ c: CameraConfig, stream: StreamDeVideo, ajustes: VigiaDeMovimento.Ajustes) -> Vigilancia {
        let vigia = VigiaDeMovimento(url: c.urlDeVideo(stream), pasta: pasta, nome: c.nome, ajustes: ajustes)
        let id = c.id
        let rotulo = "\(c.nome) (gravação)"
        let esta = ObjectIdentifier(vigia)
        vigia.aoMudarEstado = { [weak self] e in
            Depuracao.registrar("\(rotulo): \(e)")
            Task { @MainActor in
                // uma vigia já trocada por outra (senha nova, ajustes novos) não fala mais pela câmera
                guard let self, let atual = self.vigias[id]?.vigia, ObjectIdentifier(atual) == esta else { return }
                self.situacoes[id] = Self.situacao(e)
            }
        }
        vigia.aoGravar = { [weak self] r in
            Task { @MainActor in self?.gravou(r, camera: c) }
        }
        vigia.aoRecusarCredenciais = { [weak self] in
            Task { @MainActor in self?.modelo?.renovarDados(de: c, porque: .senhaRecusada) }
        }
        vigia.aoNaoResponder = { [weak self] primeiraVez in
            Task { @MainActor in self?.modelo?.renovarDados(de: c, porque: .semResposta(primeiraVez: primeiraVez)) }
        }
        vigia.iniciar()
        Depuracao.registrar("gravação: vigiando \(c.nome) no vídeo \(stream == .principal ? "HD" : "leve")")
        return Vigilancia(camera: c, stream: stream, ajustes: ajustes, vigia: vigia)
    }

    private static func situacao(_ e: VigiaDeMovimento.Estado) -> Situacao {
        switch e {
        case .parado, .conectando: return .conectando
        case .vigiando: return .vigiando
        case .gravando: return .gravando
        case .erro(let m): return .erro(m)
        }
    }

    private func gravou(_ r: Result<VigiaDeMovimento.Gravacao, GravacaoErro>, camera: CameraConfig) {
        switch r {
        case .success(let g):
            recarregarRecentes()
            modelo?.avisar("Movimento em \(camera.nome): \(Self.duracao(g.duracao)) gravados.", .ok, arquivo: g.arquivo)
        case .failure(let erro):
            modelo?.avisar("Não consegui gravar \(camera.nome): \(erro.descricao)", .erro)
        }
    }

    /// Enquanto houver vigia, o Mac não dorme sozinho e o app não cochila (App Nap); a tela pode apagar.
    private func manterAcordado(_ sim: Bool) {
        if sim, atividade == nil {
            atividade = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Gravação por movimento")
        } else if !sim, let a = atividade {
            ProcessInfo.processInfo.endActivity(a)
            atividade = nil
        }
    }

    // MARK: - Arquivos

    /// Relê a pasta: os 50 arquivos mais recentes, com a duração lida depois.
    public func recarregarRecentes() {
        let pasta = self.pasta
        let chaves: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: pasta, includingPropertiesForKeys: chaves,
                                                                  options: [.skipsHiddenFiles])) ?? []
        let conhecidas = Dictionary(recentes.map { ($0.url, $0.duracao) }, uniquingKeysWith: { a, _ in a })
        recentes = urls.filter { $0.pathExtension.lowercased() == "mp4" }
            .compactMap { u -> ArquivoGravado? in
                guard let v = try? u.resourceValues(forKeys: Set(chaves)) else { return nil }
                return ArquivoGravado(url: u, data: v.creationDate ?? .distantPast, bytes: Int64(v.fileSize ?? 0),
                                      duracao: conhecidas[u] ?? nil)
            }
            .sorted { $0.data > $1.data }
            .prefix(50)
            .map { $0 }
        let semDuracao = recentes.filter { $0.duracao == nil }.map(\.url)
        guard !semDuracao.isEmpty else { return }
        Task {
            var lidas: [URL: Double] = [:]
            for u in semDuracao {
                if let d = try? await AVURLAsset(url: u).load(.duration).seconds, d.isFinite { lidas[u] = d }
            }
            recentes = recentes.map { a in
                var a = a
                if a.duracao == nil { a.duracao = lidas[a.url] }
                return a
            }
        }
    }

    /// "42 s", "3 min 05 s".
    public static func duracao(_ segundos: Double) -> String {
        let s = Int(segundos.rounded())
        return s < 60 ? "\(s) s" : String(format: "%d min %02d s", s / 60, s % 60)
    }
}
