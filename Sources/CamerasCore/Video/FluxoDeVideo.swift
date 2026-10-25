import Foundation

/// Vídeo ao vivo de um fluxo RTSP de uma câmera: conecta, decodifica e, se a
/// conexão cair, tenta de novo com espera crescente (1, 2, 4, 8 e 10 s). Se a câmera
/// recusar o usuário e a senha, não tenta de novo: avisa por `aoRecusarCredenciais`.
/// Se várias conexões seguidas terminarem sem imagem, avisa por `aoNaoResponder` e segue tentando.
///
/// Câmera que aceita a conexão e não responde (o programa dela travou, o que as XiongMai fazem por alguns
/// minutos e depois passa sozinho) é tentada num ritmo curto e fixo, de 2 em 2 s: cada tentativa custa
/// pouco, e assim o vídeo volta logo que ela volta. O erro segue na tela entre as tentativas, em vez de
/// piscar "conectando…" a cada uma.
///
/// Cada instância ocupa UMA sessão RTSP na câmera (elas aguentam poucas);
/// `parar()` libera a sessão. Os ouvintes são chamados de threads internas.
public final class FluxoDeVideo: @unchecked Sendable {
    public enum Estado: Sendable, Equatable {
        case parado
        case conectando
        case aoVivo(codec: String, largura: Int, altura: Int)
        case erro(String)
    }

    private final class Caixa<T>: @unchecked Sendable {
        private let trava = NSLock()
        private var v: T
        init(_ v: T) { self.v = v }
        var valor: T {
            get { trava.withLock { v } }
            set { trava.withLock { v = newValue } }
        }
        /// Leitura e escrita numa única trava (para contadores).
        func atualizar(_ f: (inout T) -> Void) { trava.withLock { f(&v) } }
    }

    /// Texto de erro a mostrar quando algo falha antes de haver mensagem melhor.
    private static func resumo(_ erro: Error) -> String {
        if let e = erro as? RTSPErro { return e.descricao }
        if let e = erro as? ErroDeRede { return Redact.texto(e.description) }
        return Redact.texto(erro.localizedDescription)
    }

    private let url: String
    private let incluirAudio: Bool
    private let limiteSemVideo: TimeInterval
    private let esperaPorResposta: TimeInterval
    private let falhasAteAvisar: Int
    private let falhasEntreAvisos: Int

    private let trava = NSLock()
    private var rodando = false
    private var esperando = false                           // o laço está na pausa entre duas tentativas
    private var adiantar = false                            // `tentarAgora()` chegou fora da pausa: a próxima não espera
    private var cliente: RTSPClient?
    private let acordar = DispatchSemaphore(value: 0)
    private let terminou = DispatchGroup()                  // a thread do laço, de `iniciar()` até o fim

    private let _cameraMuda = Caixa<Bool>(false)
    private let _estado = Caixa<Estado>(.parado)
    private let _ultimoQuadro = Caixa<QuadroDecodificado?>(nil)
    private let _quadros = Caixa<Int>(0)
    private let _aoReceberQuadro = Caixa<(@Sendable (QuadroDecodificado) -> Void)?>(nil)
    private let _aoMudarEstado = Caixa<(@Sendable (Estado) -> Void)?>(nil)
    private let _aoReceberAudio = Caixa<(@Sendable (RTPPacket) -> Void)?>(nil)
    private let _aoReceberUnidade = Caixa<(@Sendable (UnidadeDeAcesso) -> Void)?>(nil)
    private let _aoConectar = Caixa<(@Sendable (SDP) -> Void)?>(nil)
    private let _aoRecusarCredenciais = Caixa<(@Sendable () -> Void)?>(nil)
    private let _aoNaoResponder = Caixa<(@Sendable (Bool) -> Void)?>(nil)

    /// `limiteSemVideo`: segundos sem nenhum quadro de vídeo que contam como câmera travada (reconecta).
    /// `esperaPorResposta`: quanto cada resposta da câmera pode demorar (veja `RTSPClient`).
    /// `falhasAteAvisar` e `falhasEntreAvisos`: quantas conexões seguidas sem imagem até `aoNaoResponder`
    /// e de quantas em quantas ele se repete enquanto durar (a 10 s por tentativa, uns 5 min).
    public init(url: String, incluirAudio: Bool = false, limiteSemVideo: TimeInterval = 8,
                esperaPorResposta: TimeInterval = 6, falhasAteAvisar: Int = 3, falhasEntreAvisos: Int = 30) {
        self.url = url
        self.incluirAudio = incluirAudio
        self.limiteSemVideo = limiteSemVideo
        self.esperaPorResposta = esperaPorResposta
        self.falhasAteAvisar = max(1, falhasAteAvisar)
        self.falhasEntreAvisos = max(1, falhasEntreAvisos)
    }

    public var estado: Estado { _estado.valor }
    /// A última conexão aceitou e a câmera não respondeu: o programa dela está travado. Quem fala com ela por
    /// outros caminhos (estado, movimento) só a atrasa enquanto isso. Volta a ser falso quando chega imagem.
    public var cameraMuda: Bool { _cameraMuda.valor }
    public var ultimoQuadro: QuadroDecodificado? { _ultimoQuadro.valor }
    public var quadrosRecebidos: Int { _quadros.valor }

    public var aoReceberQuadro: (@Sendable (QuadroDecodificado) -> Void)? {
        get { _aoReceberQuadro.valor }
        set { _aoReceberQuadro.valor = newValue }
    }
    public var aoMudarEstado: (@Sendable (Estado) -> Void)? {
        get { _aoMudarEstado.valor }
        set { _aoMudarEstado.valor = newValue }
    }
    public var aoReceberAudio: (@Sendable (RTPPacket) -> Void)? {
        get { _aoReceberAudio.valor }
        set { _aoReceberAudio.valor = newValue }
    }
    /// Cada quadro ainda comprimido, como a câmera mandou (para gravar sem recomprimir). Chega na
    /// thread do RTSP, na mesma ordem dos pacotes de áudio, antes de o quadro ser decodificado.
    public var aoReceberUnidade: (@Sendable (UnidadeDeAcesso) -> Void)? {
        get { _aoReceberUnidade.valor }
        set { _aoReceberUnidade.valor = newValue }
    }
    /// Uma conexão nova ficou pronta, antes do primeiro quadro dela: o SDP diz o codec, os
    /// parâmetros do vídeo e se há áudio. Os relógios RTP recomeçam a cada conexão.
    public var aoConectar: (@Sendable (SDP) -> Void)? {
        get { _aoConectar.valor }
        set { _aoConectar.valor = newValue }
    }
    /// A câmera recusou o usuário e a senha da URL. Chega depois do estado de erro, uma vez só.
    public var aoRecusarCredenciais: (@Sendable () -> Void)? {
        get { _aoRecusarCredenciais.valor }
        set { _aoRecusarCredenciais.valor = newValue }
    }
    /// Conexões seguidas terminaram sem imagem (recusadas, fechadas, sem resposta): o roteador pode ter
    /// dado outro endereço à câmera, e o dela a outro aparelho. Chega uma vez com `primeiraVez` e se
    /// repete, com `false`, a cada `falhasEntreAvisos` falhas enquanto não chegar imagem. O fluxo segue tentando.
    public var aoNaoResponder: (@Sendable (_ primeiraVez: Bool) -> Void)? {
        get { _aoNaoResponder.valor }
        set { _aoNaoResponder.valor = newValue }
    }

    public func iniciar() {
        trava.lock()
        guard !rodando else { trava.unlock(); return }
        rodando = true
        trava.unlock()
        terminou.enter()
        let t = Thread { [self] in
            defer { terminou.leave() }
            laco()
        }
        t.name = "fluxo-de-video"
        t.qualityOfService = .userInitiated
        t.start()
    }

    public func parar() {
        trava.lock()
        rodando = false
        let c = cliente
        trava.unlock()
        c?.parar()
        acordar.signal()
    }

    /// Como `parar()`, e espera (até `segundos`) a sessão ser devolvida à câmera. Ao fechar o app é o que
    /// faz o TEARDOWN sair antes de o processo acabar: sem isso a câmera fica com a sessão até notar a queda.
    public func parar(esperarAte segundos: TimeInterval) {
        parar()
        _ = terminou.wait(timeout: .now() + segundos)
    }

    /// A thread do fluxo já acabou (ou nunca começou): a sessão já foi devolvida à câmera.
    public var terminado: Bool { terminou.wait(timeout: .now()) == .success }

    /// Tenta de novo já, sem esperar o fim da pausa entre as tentativas (a pessoa pediu, a rede voltou). Se
    /// ela cair no meio de uma tentativa, vale para a pausa que vier depois dela.
    public func tentarAgora() {
        let acordarAgora = trava.withLock { () -> Bool in
            if !esperando { adiantar = true }
            return esperando
        }
        if acordarAgora { acordar.signal() }
    }

    private func estaRodando() -> Bool {
        trava.withLock { rodando }
    }

    private func mudar(_ novo: Estado) {
        guard _estado.valor != novo else { return }
        if case .aoVivo = novo { _cameraMuda.valor = false }
        _estado.valor = novo
        _aoMudarEstado.valor?(novo)
    }

    private enum Desfecho { case comQuadros, semQuadros, semResposta, credenciaisRecusadas }

    /// Pausa entre as tentativas de uma câmera que aceita a conexão e não responde.
    static let esperaComCameraMuda: TimeInterval = 2

    private func laco() {
        var espera = 1.0
        var falhas = 0                                     // conexões seguidas sem imagem
        var mudaDesde: Date?                               // desde quando ela aceita a conexão e não responde
        while estaRodando() {
            if falhas == 0 { mudar(.conectando) }          // nas tentativas seguintes o erro segue na tela
            let (desfecho, erro) = executarUmaSessao()
            if !estaRodando() { break }
            mudaDesde = desfecho == .semResposta ? (mudaDesde ?? Date()) : nil
            _cameraMuda.valor = desfecho == .semResposta
            if let erro { mudar(.erro(Self.texto(do: erro, mudaDesde: mudaDesde))) }
            if desfecho == .credenciaisRecusadas {
                // Com a mesma senha a resposta seria a mesma, e insistir pode fazer a câmera bloquear
                // a conta: o erro fica na tela até quem abriu o fluxo pará-lo (e abrir outro, com a nova).
                _aoRecusarCredenciais.valor?()
                while estaRodando() { _ = acordar.wait(timeout: .now() + 60) }
                break
            }
            if desfecho == .comQuadros {
                espera = 1
                falhas = 0
                trava.withLock { adiantar = false }        // o pedido era para a falha de antes, que já passou
            } else {
                espera = desfecho == .semResposta ? Self.esperaComCameraMuda : min(espera * 2, 10)
                falhas += 1
                if falhas >= falhasAteAvisar, (falhas - falhasAteAvisar) % falhasEntreAvisos == 0 {
                    _aoNaoResponder.valor?(falhas == falhasAteAvisar)
                }
            }
            while acordar.wait(timeout: .now()) == .success {}     // sinal velho (um `tentarAgora` fora da hora) não vale
            let adiantada = trava.withLock { () -> Bool in
                if adiantar { adiantar = false; return true }
                esperando = true
                return false
            }
            if !adiantada {
                if estaRodando() { _ = acordar.wait(timeout: .now() + espera) }      // `parar()` já pode ter chegado
                trava.withLock { esperando = false }
            }
        }
        mudar(.parado)
    }

    /// O que a tela mostra de um erro. A câmera que não responde diz há quanto tempo, e depois de uns
    /// minutos o que costuma resolver: a travada que passa sozinha dura de 1 a 10 minutos, e desligá-la da
    /// tomada a faz voltar na hora.
    static func texto(do erro: Error, mudaDesde: Date?, agora: Date = Date()) -> String {
        guard let mudaDesde, (erro as? RTSPErro)?.semResposta == true else { return resumo(erro) }
        let minutos = Int(agora.timeIntervalSince(mudaDesde) / 60)
        switch minutos {
        case ..<1: return "\(RTSPErro.textoSemResposta). Tentando de novo…"
        case 1..<3: return "a câmera está na rede, mas não responde há \(minutos) min. Tentando de novo…"
        default: return "a câmera está na rede, mas não responde há \(minutos) min. Tentando de novo; "
            + "se continuar assim, desligue-a da tomada por 10 s."
        }
    }

    /// Roda uma conexão até ela terminar e diz como terminou, com o erro que a encerrou (se houve).
    private func executarUmaSessao() -> (desfecho: Desfecho, erro: Error?) {
        guard let cli = RTSPClient(url: url) else {
            return (.semQuadros, RTSPErro("o endereço da câmera é inválido"))
        }
        cli.limiteSemVideo = limiteSemVideo
        cli.esperaPorResposta = esperaPorResposta
        trava.withLock { cliente = cli }
        _quadros.valor = 0
        let sessao = SessaoDeDecodificacao()
        var falha: Error?
        do {
            try cli.executar(
                incluirAudio: incluirAudio,
                aoFicarPronto: { [self] sdp in
                    let codec = try sessao.preparar(sdp: sdp) { [self] q in quandoChegarQuadro(q) }
                    sessaoCodec.valor = codec.nome
                    _aoConectar.valor?(sdp)
                },
                aoReceberVideo: { [self] p in sessao.receber(p, aoUnidade: _aoReceberUnidade.valor) },
                aoReceberAudio: { [self] p in _aoReceberAudio.valor?(p) })
        } catch {
            falha = error
        }
        sessao.encerrar()
        let rtsp = falha as? RTSPErro
        if rtsp?.credenciaisRecusadas == true { return (.credenciaisRecusadas, falha) }
        if _quadros.valor > 0 { return (.comQuadros, falha) }
        return (rtsp?.semResposta == true ? .semResposta : .semQuadros, falha)
    }

    private func quandoChegarQuadro(_ q: QuadroDecodificado) {
        _quadros.atualizar { $0 += 1 }
        _ultimoQuadro.valor = q
        mudar(.aoVivo(codec: sessaoCodec.valor, largura: q.largura, altura: q.altura))
        _aoReceberQuadro.valor?(q)
    }

    private let sessaoCodec = Caixa<String>("")

    /// Depacotador + decodificador de uma conexão. Só a thread do RTSP os usa.
    private final class SessaoDeDecodificacao: @unchecked Sendable {
        private var depacotador: Depacotador?
        private var decodificador: DecodificadorDeVideo?

        @discardableResult
        func preparar(sdp: SDP, aoQuadro: @escaping @Sendable (QuadroDecodificado) -> Void) throws -> CodecDeVideo {
            guard let video = sdp.midias.first(where: { $0.tipo == "video" }) else {
                throw RTSPErro("a câmera não anunciou vídeo")
            }
            guard let codec = CodecDeVideo(sdp: video.codificacao) else {
                throw RTSPErro("codec de vídeo não suportado: \(video.codificacao ?? "desconhecido")")
            }
            depacotador = codec == .h264 ? DepacotadorH264() : DepacotadorH265()
            let d = DecodificadorDeVideo(codec: codec, aoDecodificar: aoQuadro)
            d.semear(video.conjuntosDeParametros)
            decodificador = d
            return codec
        }

        func receber(_ p: RTPPacket, aoUnidade: (@Sendable (UnidadeDeAcesso) -> Void)?) {
            guard let depacotador, let decodificador else { return }
            for au in depacotador.empurrar(p) {
                aoUnidade?(au)
                decodificador.decodificar(au)
            }
        }

        func encerrar() {
            decodificador?.encerrar()
            decodificador = nil
            depacotador = nil
        }
    }
}
