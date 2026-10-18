import Foundation

public struct RTSPErro: Error, CustomStringConvertible, Sendable {
    public let descricao: String
    /// A câmera recusou o usuário e a senha da URL (401/403): com eles, tentar de novo não adianta.
    public let credenciaisRecusadas: Bool
    /// A mensagem passa por `Redact`: a URL das câmeras carrega usuário e senha.
    public init(_ d: String, credenciaisRecusadas: Bool = false) {
        descricao = Redact.texto(d)
        self.credenciaisRecusadas = credenciaisRecusadas
    }
    public var description: String { descricao }
}

/// Cliente RTSP com RTP entrelaçado no próprio TCP (RFC 2326), feito para as
/// câmeras XiongMai.
///
/// Particularidades dessas câmeras, vistas nas respostas reais:
/// - o RTP pode começar a chegar ANTES da resposta ao PLAY, então quadros e
///   respostas são separados por um único leitor, nunca em sequência;
/// - cada SETUP devolve um `Session` diferente; vale o do último;
/// - a trilha é aceita em `URL + "/" + a=control`, e o `Content-Base` vem sem
///   a parte `?real_stream`.
///
/// `executar` bloqueia a thread que o chama até `parar()` ou até uma falha.
public final class RTSPClient: @unchecked Sendable {
    struct Resposta {
        let status: Int
        let cabecalhos: [String: String]      // chaves em minúsculas
        let corpo: String
        var cseq: Int? { cabecalhos["cseq"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
    }

    enum Mensagem {
        case quadro(canal: Int, dados: [UInt8])
        case resposta(Resposta)
    }

    private let url: String
    private let host: String
    private let porta: UInt16

    private let trava = NSLock()
    private var pararPedido = false

    // Estado da sessão: só a thread de `executar` mexe.
    private var buffer: [UInt8] = []
    private var inicio = 0
    private var cseq = 0
    private var sessao: String?
    private var canalVideo = -1
    private var canalAudio = -1
    private var aoReceberVideo: (@Sendable (RTPPacket) -> Void)?
    private var aoReceberAudio: (@Sendable (RTPPacket) -> Void)?
    private var ultimoVideo = Date()

    /// Segundos sem vídeo que contam como câmera travada.
    public var limiteSemVideo: TimeInterval = 8

    public init?(url: String) {
        guard let c = URLComponents(string: url),
              c.scheme?.lowercased() == "rtsp",
              let h = c.host, !h.isEmpty else { return nil }
        self.url = url
        self.host = h
        self.porta = UInt16(clamping: c.port ?? 554)
    }

    public func parar() {
        trava.lock()
        pararPedido = true
        trava.unlock()
    }

    private func pararFoiPedido() -> Bool {
        trava.lock()
        defer { trava.unlock() }
        return pararPedido
    }

    // MARK: - Sessão

    public func executar(
        incluirAudio: Bool,
        aoFicarPronto: (SDP) throws -> Void,
        aoReceberVideo: @escaping @Sendable (RTPPacket) -> Void,
        aoReceberAudio: @escaping @Sendable (RTPPacket) -> Void = { _ in }
    ) throws {
        self.aoReceberVideo = aoReceberVideo
        self.aoReceberAudio = aoReceberAudio
        let soquete = TCPSocket()
        try soquete.conectar(host: host, porta: porta, timeout: 5)
        defer { soquete.fechar() }

        _ = try pedir("OPTIONS", url: url, soquete: soquete)          // algumas não respondem 200: tudo bem
        let descricao = try pedir("DESCRIBE", url: url, cabecalhos: [("Accept", "application/sdp")], soquete: soquete)
        guard descricao.status == 200 else { throw erroDeStatus("DESCRIBE", descricao.status) }
        let sdp = SDP.interpretar(descricao.corpo)
        guard sdp.midias.contains(where: { $0.tipo == "video" }) else {
            throw RTSPErro("a câmera não anunciou vídeo")
        }
        try aoFicarPronto(sdp)

        let base = descricao.cabecalhos["content-base"]
        var canal = 0
        for midia in sdp.midias where midia.tipo == "video" || (incluirAudio && midia.tipo == "audio") {
            let atribuido = try configurarTrilha(midia, canal: canal, base: base, soquete: soquete)
            if midia.tipo == "video" { canalVideo = atribuido } else { canalAudio = atribuido }
            canal += 2
        }

        let play = try pedir("PLAY", url: url, cabecalhos: [("Range", "npt=0.000-")], soquete: soquete)
        guard play.status == 200 else { throw erroDeStatus("PLAY", play.status) }

        ultimoVideo = Date()
        var ultimoKeepalive = Date()
        while !pararFoiPedido() {
            if let m = try lerMensagem(timeout: 0.25, soquete: soquete), case .quadro(let c, let d) = m {
                despachar(canal: c, dados: d)
            }
            let agora = Date()
            if agora.timeIntervalSince(ultimoVideo) > limiteSemVideo {
                throw RTSPErro("a câmera parou de enviar vídeo")
            }
            if agora.timeIntervalSince(ultimoKeepalive) >= 20 {
                try enviar("OPTIONS", url: url, soquete: soquete)      // a resposta é descartada no laço
                ultimoKeepalive = agora
            }
        }
        // Parada pedida: libera a sessão na câmera sem esperar resposta (há quadros no caminho).
        try? enviar("TEARDOWN", url: url, soquete: soquete)
    }

    private func configurarTrilha(_ midia: SDP.Midia, canal: Int, base: String?,
                                  soquete: TCPSocket) throws -> Int {
        var candidatas = [urlDaTrilha(midia.controle, base: url + (url.hasSuffix("/") ? "" : "/"))]
        if let base, let alt = Optional(urlDaTrilha(midia.controle, base: base)), alt != candidatas[0] {
            candidatas.append(alt)
        }
        var ultimoStatus = 0
        for alvo in candidatas {
            let r = try pedir("SETUP", url: alvo,
                              cabecalhos: [("Transport", "RTP/AVP/TCP;unicast;interleaved=\(canal)-\(canal + 1)")],
                              soquete: soquete)
            ultimoStatus = r.status
            guard r.status == 200 else { continue }
            if let s = r.cabecalhos["session"] {
                sessao = s.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }
            }
            if let t = r.cabecalhos["transport"], let a = Self.canalEntrelacado(t) { return a }
            return canal
        }
        throw erroDeStatus("SETUP", ultimoStatus)
    }

    private func urlDaTrilha(_ controle: String?, base: String) -> String {
        guard let c = controle, !c.isEmpty, c != "*" else { return url }
        if c.lowercased().hasPrefix("rtsp://") { return c }
        return base + c
    }

    static func canalEntrelacado(_ transporte: String) -> Int? {
        for parte in transporte.split(separator: ";") {
            let p = parte.trimmingCharacters(in: .whitespaces)
            if p.hasPrefix("interleaved=") {
                return Int(p.dropFirst("interleaved=".count).split(separator: "-").first ?? "")
            }
        }
        return nil
    }

    private func erroDeStatus(_ metodo: String, _ status: Int) -> RTSPErro {
        switch status {
        case 401, 403: return RTSPErro("\(metodo): a câmera recusou o usuário ou a senha (\(status))", credenciaisRecusadas: true)
        case 404: return RTSPErro("\(metodo): a câmera não achou o fluxo pedido (404)")
        case 453, 503: return RTSPErro("\(metodo): a câmera está sem sessões livres (\(status))")
        default: return RTSPErro("\(metodo): resposta inesperada da câmera (\(status))")
        }
    }

    // MARK: - Pedidos e leitura

    private func montar(_ metodo: String, url: String, cabecalhos: [(String, String)]) -> (Int, [UInt8]) {
        cseq += 1
        var req = "\(metodo) \(url) RTSP/1.0\r\nCSeq: \(cseq)\r\nUser-Agent: CamerasDeCasa\r\n"
        if let s = sessao { req += "Session: \(s)\r\n" }
        for (k, v) in cabecalhos { req += "\(k): \(v)\r\n" }
        req += "\r\n"
        return (cseq, Array(req.utf8))
    }

    private func enviar(_ metodo: String, url: String, cabecalhos: [(String, String)] = [],
                        soquete: TCPSocket) throws {
        try soquete.escrever(montar(metodo, url: url, cabecalhos: cabecalhos).1)
    }

    @discardableResult
    private func pedir(_ metodo: String, url: String, cabecalhos: [(String, String)] = [],
                       soquete: TCPSocket, timeout: TimeInterval = 8) throws -> Resposta {
        let (meu, bytes) = montar(metodo, url: url, cabecalhos: cabecalhos)
        try soquete.escrever(bytes)
        let limite = Date().addingTimeInterval(timeout)
        while true {
            if pararFoiPedido() { throw RTSPErro("interrompido") }
            let restante = limite.timeIntervalSinceNow
            if restante <= 0 { throw RTSPErro("\(metodo): a câmera não respondeu em \(Int(timeout)) s") }
            guard let m = try lerMensagem(timeout: min(0.25, restante), soquete: soquete) else { continue }
            switch m {
            case .quadro(let c, let d): despachar(canal: c, dados: d)
            case .resposta(let r): if r.cseq == meu { return r }
            }
        }
    }

    private func despachar(canal: Int, dados: [UInt8]) {
        if canal == canalVideo, let p = RTPPacket(bytes: dados) {
            ultimoVideo = Date()
            aoReceberVideo?(p)
        } else if canal == canalAudio, let p = RTPPacket(bytes: dados) {
            aoReceberAudio?(p)
        }   // canais ímpares são RTCP: ignorados
    }

    private func lerMensagem(timeout: TimeInterval, soquete: TCPSocket) throws -> Mensagem? {
        while true {
            if let m = try extrairMensagem() { return m }
            guard let novos = try soquete.ler(maximo: 65536, timeout: timeout) else { return nil }
            buffer.append(contentsOf: novos)
        }
    }

    private func consumir(_ n: Int) {
        inicio += n
        if inicio >= buffer.count {
            buffer.removeAll(keepingCapacity: true)
            inicio = 0
        } else if inicio > 1 << 20 {
            buffer.removeFirst(inicio)
            inicio = 0
        }
    }

    /// Tira uma mensagem completa do buffer, ou devolve nil se ainda faltam bytes.
    private func extrairMensagem() throws -> Mensagem? {
        // linhas em branco soltas entre mensagens
        while inicio < buffer.count, buffer[inicio] == 13 || buffer[inicio] == 10 { consumir(1) }
        let disponivel = buffer.count - inicio
        guard disponivel > 0 else { return nil }

        if buffer[inicio] == 0x24 {                                   // '$': quadro RTP/RTCP
            guard disponivel >= 4 else { return nil }
            let tam = Int(buffer[inicio + 2]) << 8 | Int(buffer[inicio + 3])
            guard disponivel >= 4 + tam else { return nil }
            let canal = Int(buffer[inicio + 1])
            let dados = Array(buffer[(inicio + 4)..<(inicio + 4 + tam)])
            consumir(4 + tam)
            return .quadro(canal: canal, dados: dados)
        }

        guard buffer[inicio] == 0x52 else {                            // 'R' de "RTSP/1.0"
            throw RTSPErro("dados inesperados no fluxo da câmera")
        }
        guard let fim = fimDoCabecalho() else {
            if disponivel > 32768 { throw RTSPErro("resposta da câmera sem fim de cabeçalho") }
            return nil
        }
        let texto = String(decoding: buffer[inicio..<fim], as: UTF8.self)
        var linhas = texto.components(separatedBy: "\r\n")
        let primeira = linhas.removeFirst()
        let partes = primeira.split(separator: " ", maxSplits: 2)
        guard partes.count >= 2, partes[0].hasPrefix("RTSP/"), let status = Int(partes[1]) else {
            throw RTSPErro("resposta RTSP inválida")
        }
        var cab: [String: String] = [:]
        for l in linhas {
            guard let i = l.firstIndex(of: ":") else { continue }
            cab[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let tamCorpo = cab["content-length"].flatMap { Int($0) } ?? 0
        let total = (fim + 4 - inicio) + tamCorpo
        guard disponivel >= total else { return nil }
        let corpo = String(decoding: buffer[(fim + 4)..<(fim + 4 + tamCorpo)], as: UTF8.self)
        consumir(total)
        return .resposta(Resposta(status: status, cabecalhos: cab, corpo: corpo))
    }

    private func fimDoCabecalho() -> Int? {
        var i = inicio
        let n = buffer.count
        while i + 3 < n {
            if buffer[i] == 13, buffer[i + 1] == 10, buffer[i + 2] == 13, buffer[i + 3] == 10 { return i }
            i += 1
        }
        return nil
    }
}
