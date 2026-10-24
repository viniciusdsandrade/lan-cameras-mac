import Foundation
import CoreMedia

/// Vigia uma câmera e grava enquanto houver movimento: o arquivo começa `antes` segundos antes de o
/// movimento ser notado (a vigia guarda sempre os últimos segundos) e termina `depois` segundos
/// depois do último movimento. Gravações longas viram vários arquivos de até `duracaoMaxima`.
///
/// Ocupa UMA sessão RTSP na câmera enquanto estiver ligada (a do vídeo principal ou do leve, com
/// som), e reconecta sozinha como o vídeo da tela. Se a conexão cair no meio de uma gravação, o
/// arquivo é fechado com o que chegou. Os ouvintes são chamados de threads internas.
public final class VigiaDeMovimento: @unchecked Sendable {
    public struct Ajustes: Sendable, Equatable {
        public var sensibilidade: SensibilidadeDeMovimento
        public var gravarSom: Bool
        /// Segundos gravados antes de o movimento ser notado.
        public var antes: Double
        /// Segundos que a gravação segue depois do último movimento.
        public var depois: Double
        /// Gravações mais longas que isto são divididas em vários arquivos.
        public var duracaoMaxima: Double

        public init(sensibilidade: SensibilidadeDeMovimento = .media, gravarSom: Bool = true,
                    antes: Double = 5, depois: Double = 10, duracaoMaxima: Double = 600) {
            self.sensibilidade = sensibilidade
            self.gravarSom = gravarSom
            self.antes = antes
            self.depois = depois
            self.duracaoMaxima = duracaoMaxima
        }
    }

    public enum Estado: Sendable, Equatable {
        case parado
        case conectando
        case vigiando
        case gravando
        case erro(String)
    }

    /// Um arquivo pronto.
    public struct Gravacao: Sendable, Equatable {
        public let arquivo: URL
        public let inicio: Date
        public let duracao: Double
        public let comSom: Bool
    }

    private final class Caixa<T>: @unchecked Sendable {
        private let trava = NSLock()
        private var v: T
        init(_ v: T) { self.v = v }
        var valor: T {
            get { trava.withLock { v } }
            set { trava.withLock { v = newValue } }
        }
        /// Leitura e escrita numa única trava.
        func atualizar<R>(_ f: (inout T) -> R) -> R { trava.withLock { f(&v) } }
    }

    /// Tempo dos quadros decodificados, para o analisador, e quando o último movimento foi avisado.
    private struct RelogioDosQuadros {
        var ultimo: UInt32?
        var segundos = 0.0
        var ultimoAviso: Double?
    }

    public let ajustes: Ajustes
    private let fluxo: FluxoDeVideo
    private let pasta: URL
    private let nome: String
    private let analisador: AnalisadorDeMovimento
    private let fila = DispatchQueue(label: "vigia-de-movimento", qos: .userInitiated)
    private let terminando = DispatchGroup()

    private let _estado = Caixa<Estado>(.parado)
    private let _aoMudarEstado = Caixa<(@Sendable (Estado) -> Void)?>(nil)
    private let _aoGravar = Caixa<(@Sendable (Result<Gravacao, GravacaoErro>) -> Void)?>(nil)
    private let relogioDosQuadros = Caixa(RelogioDosQuadros())

    // Tudo daqui para baixo só a `fila` mexe.
    private var linha = LinhaDoTempo()
    private var parametros: ParametrosDeVideo?
    private var comAudio = false
    private var memoria: MemoriaDePreGravacao
    private var gravador: GravadorDeVideo?
    private var inicioDoArquivo = Date()
    private var ultimoMovimento: Double?
    /// Onde terminou o último arquivo: o próximo não repete o que já foi gravado.
    private var fimDoUltimoArquivo: Double?
    /// Quando um arquivo não pôde ser criado: não tenta de novo a cada movimento.
    private var ultimaFalha: Double?
    private var ultimoQuadro = 0.0
    private var conectado = false
    private var parado = false

    /// `url`: o fluxo RTSP (carrega usuário e senha). `pasta`: onde ficam os arquivos. `nome`: começo
    /// do nome de cada arquivo (o da câmera). `analisador`: quem decide o que é movimento (por
    /// padrão, um `DetectorDeMovimento` com a sensibilidade dos ajustes).
    public init(url: String, pasta: URL, nome: String, ajustes: Ajustes = Ajustes(),
                analisador: AnalisadorDeMovimento? = nil, limiteSemVideo: TimeInterval = 8) {
        self.ajustes = ajustes
        self.pasta = pasta
        self.nome = Self.nomeDeArquivo(nome)
        self.analisador = analisador ?? DetectorDeMovimento(sensibilidade: ajustes.sensibilidade)
        memoria = MemoriaDePreGravacao(duracao: ajustes.antes + 3)       // folga para a análise que chega atrasada
        fluxo = FluxoDeVideo(url: url, incluirAudio: ajustes.gravarSom, limiteSemVideo: limiteSemVideo)

        fluxo.aoConectar = { [weak self] sdp in self?.conectou(sdp) }
        fluxo.aoReceberUnidade = { [weak self] au in
            guard let self else { return }
            let chegada = ProcessInfo.processInfo.systemUptime
            fila.async { [self] in receber(au, chegada: chegada) }
        }
        fluxo.aoReceberAudio = { [weak self] p in
            guard let self, p.tipoDeCarga == 8, !p.carga.isEmpty else { return }          // 8 = PCMA
            let chegada = ProcessInfo.processInfo.systemUptime
            fila.async { [self] in receberAudio(p, chegada: chegada) }
        }
        fluxo.aoReceberQuadro = { [weak self] q in self?.analisar(q) }
        fluxo.aoMudarEstado = { [weak self] e in
            guard let self else { return }
            fila.async { [self] in fluxoMudou(e) }
        }
    }

    public var estado: Estado { _estado.valor }

    public var aoMudarEstado: (@Sendable (Estado) -> Void)? {
        get { _aoMudarEstado.valor }
        set { _aoMudarEstado.valor = newValue }
    }
    /// Um arquivo ficou pronto, ou não pôde ser gravado (disco cheio, pasta sem permissão).
    public var aoGravar: (@Sendable (Result<Gravacao, GravacaoErro>) -> Void)? {
        get { _aoGravar.valor }
        set { _aoGravar.valor = newValue }
    }
    /// Como no vídeo da tela: a câmera recusou a senha e a vigia parou de tentar.
    public var aoRecusarCredenciais: (@Sendable () -> Void)? {
        get { fluxo.aoRecusarCredenciais }
        set { fluxo.aoRecusarCredenciais = newValue }
    }
    /// Como no vídeo da tela: a câmera não responde no endereço guardado; a vigia segue tentando.
    public var aoNaoResponder: (@Sendable (_ primeiraVez: Bool) -> Void)? {
        get { fluxo.aoNaoResponder }
        set { fluxo.aoNaoResponder = newValue }
    }

    deinit { fluxo.parar() }

    public func iniciar() {
        fila.async { [self] in if !parado { mudar(.conectando) } }
        fluxo.iniciar()
    }

    /// Solta a sessão na câmera e fecha o arquivo em curso (em segundo plano).
    public func parar() {
        fluxo.parar()
        fila.async { [self] in
            parado = true
            conectado = false
            encerrarGravacao()
            mudar(.parado)
        }
    }

    /// Espera os arquivos em curso ficarem prontos (ao fechar o app). Devolve false se o tempo acabou.
    @discardableResult
    public func esperarArquivos(ate segundos: Double) -> Bool {
        fila.sync {}
        return terminando.wait(timeout: .now() + segundos) == .success
    }

    // MARK: - Conexão

    /// Thread do RTSP, antes do primeiro pacote da conexão nova.
    private func conectou(_ sdp: SDP) {
        analisador.reiniciar()
        relogioDosQuadros.valor = RelogioDosQuadros()
        let audio = ajustes.gravarSom && sdp.midias.contains { $0.tipo == "audio" && $0.codificacao == "PCMA" }
        fila.async { [self] in
            guard !parado else { return }
            encerrarGravacao()
            linha = LinhaDoTempo()
            memoria.esvaziar()
            ultimoMovimento = nil
            fimDoUltimoArquivo = nil
            ultimaFalha = nil
            comAudio = audio
            parametros = nil
            if let video = sdp.midias.first(where: { $0.tipo == "video" }), let codec = CodecDeVideo(sdp: video.codificacao) {
                var p = ParametrosDeVideo(codec: codec)
                for nal in video.conjuntosDeParametros { p.guardar(nal) }
                parametros = p
            }
        }
    }

    private func fluxoMudou(_ e: FluxoDeVideo.Estado) {
        guard !parado else { return }
        switch e {
        case .aoVivo:
            if !conectado {
                conectado = true
                mudar(gravador == nil ? .vigiando : .gravando)
            }
        case .conectando:
            conectado = false
            encerrarGravacao()
            mudar(.conectando)
        case .erro(let m):
            conectado = false
            encerrarGravacao()
            mudar(.erro(m))
        case .parado:
            break
        }
    }

    // MARK: - Chegada

    private func receber(_ au: UnidadeDeAcesso, chegada: Double) {
        guard !parado, var p = parametros else { return }
        var mudou = false
        for nal in au.nals where p.guardar(nal) { mudou = true }
        parametros = p
        if mudou {
            // formato novo (outra resolução, por exemplo): o que está guardado é do antigo
            encerrarGravacao()
            memoria.esvaziar()
        }
        let t = linha.video(au.timestamp, chegada: chegada)
        ultimoQuadro = t
        let item = MemoriaDePreGravacao.Item.video(au, t)
        memoria.guardar(item)
        if gravador != nil { continuar(com: item) }
    }

    private func receberAudio(_ p: RTPPacket, chegada: Double) {
        guard !parado, comAudio, let t = linha.audio(amostras: p.carga.count, chegada: chegada) else { return }
        let item = MemoriaDePreGravacao.Item.audio(ALaw.decodificar(p.carga), t)
        memoria.guardar(item)
        if gravador != nil { continuar(com: item) }
    }

    /// Thread do decodificador: um quadro pronto para análise.
    private func analisar(_ q: QuadroDecodificado) {
        let tempo = relogioDosQuadros.atualizar { r -> Double in
            if let u = r.ultimo { r.segundos += max(0, Double(Int32(bitPattern: q.timestamp &- u)) / LinhaDoTempo.taxaDoVideo) }
            r.ultimo = q.timestamp
            return r.segundos
        }
        guard analisador.analisar(q, em: tempo) else { return }
        // um aviso a cada 0,2 s basta para manter a gravação andando
        let avisar = relogioDosQuadros.atualizar { r -> Bool in
            if let a = r.ultimoAviso, tempo >= a, tempo - a < 0.2 { return false }
            r.ultimoAviso = tempo
            return true
        }
        guard avisar else { return }
        let timestamp = q.timestamp
        fila.async { [self] in movimento(timestamp) }
    }

    // MARK: - Gravação

    private func movimento(_ timestamp: UInt32) {
        guard !parado, let t = linha.quadro(timestamp) else { return }
        ultimoMovimento = max(ultimoMovimento ?? t, t)
        if gravador == nil { comecar(em: t) }
    }

    private func comecar(em t: Double) {
        if let f = ultimaFalha, t - f < 30 { return }
        var itens = memoria.desde(t, antes: ajustes.antes)
        if let fim = fimDoUltimoArquivo {
            // não repetir o fim do arquivo anterior: começa no primeiro quadro de referência depois dele
            guard let i = itens.firstIndex(where: { $0.chave && $0.tempo > fim }) else { return }
            itens = itens[i...]
        }
        guard let primeiro = itens.first, primeiro.chave, abrirArquivo(comecandoEm: primeiro.tempo) else { return }
        for item in itens {
            continuar(com: item)
            if gravador == nil { break }
        }
    }

    private func continuar(com item: MemoriaDePreGravacao.Item) {
        guard let g = gravador else { return }
        switch item {
        case .video(let au, let t):
            if let u = ultimoMovimento, t > u + ajustes.depois {
                encerrarGravacao()
                return
            }
            if au.chave, let p = g.primeiroQuadro, t - p >= ajustes.duracaoMaxima - 0.001 {
                encerrarGravacao()
                guard abrirArquivo(comecandoEm: t) else { return }
                continuar(com: item)
                return
            }
            if !g.escrever(au, em: t) { encerrarGravacao() }
        case .audio(let pcm, let t):
            g.escrever(audio: pcm, em: t)
        }
    }

    private func abrirArquivo(comecandoEm t: Double) -> Bool {
        guard let p = parametros, let descricao = p.descricao() else { return false }
        let inicio = Date().addingTimeInterval(-(ultimoQuadro - t))
        let destino = Self.destinoLivre(pasta: pasta, nome: nome, data: inicio)
        do {
            gravador = try GravadorDeVideo(destino: destino, codec: p.codec, descricao: descricao, comAudio: comAudio)
            inicioDoArquivo = inicio
            mudar(.gravando)
            return true
        } catch {
            ultimaFalha = t
            _aoGravar.valor?(.failure(error as? GravacaoErro ?? GravacaoErro(error.localizedDescription)))
            return false
        }
    }

    private func encerrarGravacao() {
        guard let g = gravador else { return }
        gravador = nil
        fimDoUltimoArquivo = g.ultimoQuadro ?? fimDoUltimoArquivo
        let inicio = inicioDoArquivo, duracao = g.duracao, comSom = g.temAudio
        let aoGravar = _aoGravar
        terminando.enter()
        g.terminar { [terminando] r in
            switch r {
            case .success(let url):
                aoGravar.valor?(.success(Gravacao(arquivo: url, inicio: inicio, duracao: duracao, comSom: comSom)))
            case .failure(let erro):
                aoGravar.valor?(.failure(erro as? GravacaoErro ?? GravacaoErro(erro.localizedDescription)))
            }
            terminando.leave()
        }
        if conectado, !parado { mudar(.vigiando) }
    }

    private func mudar(_ novo: Estado) {
        guard _estado.valor != novo else { return }
        _estado.valor = novo
        _aoMudarEstado.valor?(novo)
    }

    // MARK: - Arquivos

    static func nomeDeArquivo(_ nome: String) -> String {
        let limpo = nome.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return limpo.isEmpty ? "Câmera" : limpo
    }

    /// `pasta/Nome-AAAAMMDD-HHMMSS.mp4`, com "-2", "-3"… se já existir.
    static func destinoLivre(pasta: URL, nome: String, data: Date) -> URL {
        let formato = DateFormatter()
        formato.locale = Locale(identifier: "en_US_POSIX")
        formato.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(nome)-\(formato.string(from: data))"
        var destino = pasta.appendingPathComponent(base + ".mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: destino.path) {
            destino = pasta.appendingPathComponent("\(base)-\(n).mp4")
            n += 1
        }
        return destino
    }
}
